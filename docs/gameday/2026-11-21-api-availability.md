# Game day 2026-11-21: Kubernetes API availability under failure

- **Objective:** measure, rather than assume, Kubernetes API availability
  through the load-balanced VIP when load balancers and control-plane nodes
  fail.
- **Method:** `scripts/gameday/api-probe.sh` sampled
  `https://10.97.3.100:6443/readyz` every 200 ms from the engineering
  workstation. Every outage figure below is the measured interval between the
  first failed sample and the next successful one
  (`scripts/gameday/api-probe-summary.sh`). Failures were injected with
  `systemctl stop` (process failure) and `multipass stop --force` (immediate
  power-off, no graceful shutdown).
- **Preconditions:** all checks passed before each experiment: five nodes
  Ready, three etcd members healthy, no unhealthy kube-system pods, all hosts
  within 0.5 ms of NTP (after the
  [clock-drift fix](../incidents/2026-11-21-clock-drift-after-host-suspend.md)).

## Results

| # | Failure injected | Measured API outage | Outcome |
|---|---|---|---|
| G0 | None (baseline, 30 s) | 0 s, 132/132 samples OK | Healthy reference |
| E1 | HAProxy stopped on the VIP holder for 45 s | **5.3 s** | VIP moved to LB2; failback when HAProxy returned had **zero** failed samples |
| E2 | VIP holder powered off, then rebooted | 3.6 s at crash; reboot exposed two defects (below) | **Fail**: HAProxy could not start at boot; 16 s dual-MASTER |
| E2b | Same, after fixing defect 1 | 3.6 s at crash, **36.5 s** at reboot | **Fail**: defect 2 |
| E2c | Same, after fixing defects 1 and 2 | **3.6 s** at crash, **0 s** at reboot | Pass |
| E3 | etcd leader (tf-ha-control2) powered off; production-debug incident demo run during the outage | No full outage; **10 of 1,856 samples failed** over a 16 s window (99.46% over 7 min) | Pass, with a tuning finding |
| E4 | etcd isolated restore drill (runbook procedure) | n/a (offline) | Pass |

## E1: HAProxy process failure

Timeline (UTC): HAProxy stopped 17:40:05 → health check failing 17:40:06 →
declared failed 17:40:08 (`fall 2`, `interval 2`) → VIP on LB2 17:40:11.
During those ~5 s the VIP stayed on a node with no listener, so clients
received `connection refused`.

**Recommendation (not applied):** tighten `keepalived_haproxy_check_interval`
and `fall` to reduce detection time. This trades sensitivity for
false-failover risk and should be decided deliberately.

## E2: load-balancer crash and reboot — two latent defects

### Defect 1: HAProxy cannot start after reboot

```text
cannot bind socket (Cannot assign requested address) for [10.97.3.100:6443]
```

HAProxy binds the VIP, which the backup node does not hold, so it relies on
`net.ipv4.ip_nonlocal_bind=1`. The `haproxy` role wrote that setting to
`/etc/sysctl.conf` (the Ansible module default). On Ubuntu 26.04,
systemd-sysctl no longer reads that file, so the setting was lost on every
reboot. systemd gave up after five restarts and the rebooted load balancer
had **no HAProxy**, removing API redundancy without any alert.

**Fix:** the setting now lives in `/etc/sysctl.d/90-haproxy-nonlocal-bind.conf`,
the role asserts the live value, and a regression test requires every
`ansible.posix.sysctl` task to write under `/etc/sysctl.d/`. Applied to both
load balancers through `02-load-balancers.yml`; the second run was
idempotent.

### Defect 2: 36.5 s outage on failback (STP on the frontend bridge)

With defect 1 fixed, the reboot produced a 36.5 s outage. Sequence (UTC):

| Time | Event |
|---|---|
| 17:51:42 | Rebooted LB1 claims MASTER; LB2 never receives its adverts |
| 17:51:58 | LB1's adverts arrive; LB2 steps down and removes the VIP (outage starts) |
| 17:52:35 | Workstation's ARP entry for the VIP expires and is re-resolved to LB1 (outage ends) |

All failed samples were timeouts, not refusals: traffic went to LB2's stale
MAC address. The host bridge `br-api-frontend` had **STP enabled**
(NetworkManager's default) with a 15 s forward delay, so every newly booted
load balancer's port dropped traffic, including VRRP adverts and gratuitous
ARPs, while STP was learning. The Multipass zone bridges have STP off.

ADR-004's earlier "validated" failover test stopped keepalived, which never
exercises a VM boot, so this was not visible before.

**Fix:** `scripts/host-frontend-bridge.sh` codifies the bridge with STP
disabled (safe: the bridge has only VM ports and no redundant links) and
applies the change in place with `nmcli device reapply`. Applied with a probe
running: 203/203 samples OK, both VM ports stayed attached.

### Verification (E2c)

Crash failover 3.6 s (VRRP master-down timer). On reboot, LB1 received LB2's
adverts four seconds after boot, preempted cleanly, and the failback produced
**zero** failed samples. No dual-MASTER.

## E3: etcd leader loss during an investigation

tf-ha-control2 was both a control-plane node and the etcd leader. It was
powered off at 17:59:21 UTC, and the full production-debug incident demo
(break, isolate, prove least privilege, collect evidence, AI investigation
over MCP, remediate, verify, clean up) was run while it was down.

- **etcd:** leadership moved to tf-ha-control1; quorum held on two of three
  members.
- **Demo:** passed all eight steps (exit 0). Evidence collection recorded
  `status=complete` with no failed and no retried steps: in-cluster clients
  reach the API through the `kubernetes` Service, not the VIP.
- **Recovery:** tf-ha-control2 was booted at 18:02:00 and its node was Ready
  at 18:02:32; all three etcd members were healthy afterwards.

### Finding: ~16 s of partial failure through the VIP

The probe recorded 10 failed samples between 17:59:23 and 17:59:39, each a
1 s timeout, interleaved with successes. HAProxy balances round-robin, so
roughly one new connection in three went to the powered-off backend until
health checks removed it. With `check inter 3s`, the default `fall 3` and
`timeout check 3s`, removal takes up to ~18 s, matching the observation.

**Recommendation (not applied):** faster backend checks (for example
`inter 1s fall 2`), a short `timeout connect`, and `option redispatch` with
`retries`, so a connection to a dead backend is retried on a healthy one.
Validate by repeating E3.

## E4: etcd isolated restore drill

Performed on tf-ha-control1 following
[the runbook](../runbooks/etcd-backup-restore.md#isolated-restore-test): the
latest snapshot was restored into a temporary data directory; the live etcd
member was not stopped or touched.

| Evidence | Value |
|---|---|
| Snapshot | `etcd-snapshot-tf-ha-control1-20261121_160443Z.db` (7,573,536 bytes) |
| Restore exit status | 0 |
| Revision | 1,147,766 |
| Keys | 418 |
| Restored layout | `member/snap`, `member/wal` |
| Cleanup | Temporary directory removed; `/var/lib/etcd` untouched |

This proves the snapshot is restorable. It does not prove a full
cluster-recovery procedure; that remains a separate, disruptive drill.

## Findings and follow-ups

| Finding | Status |
|---|---|
| HAProxy could not start after any LB reboot (sysctl persistence) | Fixed and verified (E2c) |
| STP on the frontend bridge caused dual-MASTER and a ~37 s outage on failback | Fixed and verified (E2c) |
| ~5 s `connection refused` window when HAProxy dies on the VIP holder | Recommendation recorded; not changed |
| ~16 s partial failure (1 in 3 connections) while HAProxy detects a dead API server | Recommendation recorded; not changed |
| Full cluster restore from snapshot not yet exercised | Open; disruptive drill to schedule separately |
| cilium-operator crash loops on VIP `connection refused` (open since before this game day) | Both defects above are plausible causes; confirm by watching restarts over the next days |

## Reproducing

```bash
scripts/gameday/api-probe.sh /tmp/probe.csv 180 &
# inject a failure, e.g.: multipass stop --force api-lb1-new; sleep 45; multipass start api-lb1-new
wait; scripts/gameday/api-probe-summary.sh /tmp/probe.csv
scripts/host-frontend-bridge.sh check
```
