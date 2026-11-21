# Incident: Cluster-wide Clock Drift After Host Suspend

- **Date:** 2026-11-21
- **Status:** Resolved 2026-11-21. Clocks corrected on all hosts;
  kube-apiserver on tf-ha-control2 returned to kubelet management without a
  restart. API VIP refusals remain open (section 7).
- **Severity:** Degraded control plane (intermittent API authentication
  failures, unmanaged API server, operator crash loops)
- **Affected components:** chrony on all VMs; kube-apiserver token
  validation; etcd peer probing; kubelet static-pod management on
  tf-ha-control2; cilium-operator
- **Environment:** Multipass/QEMU on a single desktop host

## 1. Summary

The clocks of the cluster VMs disagreed by up to about 4.5 hours.

chrony was running on every VM and could reach its NTP servers, so every
VM *knew* its offset. However, the Ubuntu default `makestep 1 3` allows
chrony to step the clock only during the first three updates after it
starts. After the desktop host suspended and resumed, the resumed VMs had
large offsets that chrony could only slew, at a rate that would take hours
or days to correct.

The skew caused service-account tokens issued by one API server to be
rejected as "not valid yet" by another, producing intermittent HTTP 401
responses for valid in-cluster clients.

A separate fault was found during the investigation: the kube-apiserver
static pod on tf-ha-control2 had been running outside the kubelet's
management since 2026-11-18, because a CreateContainer call completed in
containerd but its response never reached the kubelet.

## 2. Symptoms and evidence

Offsets reported by `chronyc tracking` (2026-11-21, approximately 16:40 UTC):

| Host | System time vs NTP | Synchronised |
|---|---|---|
| api-lb1-new | 1802 s fast | no |
| api-lb2-new | 1816 s fast | no |
| tf-ha-control1 | 1810 s fast | no |
| tf-ha-control2 | 1809 s fast | no |
| tf-ha-control3 | 14027 s slow | no |
| tf-ha-worker1 | 1818 s fast | no |
| tf-ha-worker2 | 0.0000001 s | yes |

The operator workstation was NTP-synchronised and agreed with an external
HTTPS `Date` header, establishing it as the reference.

Observed effects:

- kube-apiserver on tf-ha-control3 logged
  `Unable to authenticate the request ... service account token is not valid yet`.
  Requests through the `kubernetes` Service failed only when routed to
  that API server, so failures were intermittent.
- etcd on tf-ha-control1 and tf-ha-control2 logged 202
  `prober found high clock drift` warnings in two hours each, reporting
  `clock-drift: 4h26m32s` against the tf-ha-control3 member.
- Pod ages and event times were inconsistent (for example, a 14-second-old
  pod showing its last restart "32m ago"), because timestamps were written
  by different clocks.
- `chronyc -n sources` showed reachable, selected sources on every host;
  NTP reachability was not the problem.

## 3. Root cause

1. All hosts ran chrony with Ubuntu's default `makestep 1 3`.
2. The desktop host suspended and resumed (host journal:
   `System returned from sleep operation 'suspend'` at 2026-11-21
   11:36:01 EST). The VMs were paused and resumed with it. Earlier
   `Can't synchronise: no selectable sources` events line up across all
   VMs at the same local times, consistent with earlier suspend cycles.
3. After resume, chrony could only slew the large offsets, which
   persisted across all VMs except where chronyd had restarted.
4. tf-ha-worker2's chronyd restarted at the moment of the 11:36:01
   resume (its PID changed), so its initial-step allowance applied and it
   corrected immediately. That is why it was the only correct host.

Why the clocks moved forward on most hosts rather than falling behind
was not established; the corrective action does not depend on it.

## 4. Related finding: kube-apiserver on tf-ha-control2 not managed by the kubelet

The kubelet reported `CreateContainerError` for
`kube-apiserver-tf-ha-control2` 11,568 times over three days:

```text
failed to reserve container name "kube-apiserver_..._189":
name "kube-apiserver_..._189" is reserved for "f4851759..."
```

`crictl` showed container attempt 189 (`f4851759...`) **running** and
listening on `:6443`. The API server served traffic, but the kubelet did
not manage it, so manifest changes or upgrades on that node would not have
taken effect.

### Mechanism

The kubelet treats the container with the newest `createdAt` as the
current instance. The container records were:

| Attempt | State | createdAt (epoch ns) |
|---|---|---|
| 188 | exited | 1795023874674674538 |
| 189 | running | 1795006981848075111 |

Attempt 188 was created first, but carries a creation time about 4.7 hours
*later* than attempt 189, because the node clock jumped backwards between the
two creates. The kubelet therefore concluded the API server had exited,
and kept trying to create attempt 188 + 1 = 189, a name already held by the
running container.

### Recovery and what did not work

1. Restarting the kubelet: **no effect** (still retried attempt 189).
2. Restarting containerd, then the kubelet: **no effect**. The timestamps are
   persisted, so no restart can fix the ordering.
3. Removing the exited attempt-188 container (its last 300 log lines were
   saved first): **resolved**. The kubelet adopted running container
   `f4851759...` within seconds. The API server was never restarted; the pod
   reports `1/1 Running` and `livez` returns `ok`.

`12-recover-static-pod.yml` now implements step 3 only: it selects exited
containers of the same pod whose `createdAt` is newer than the single
running container, saves their logs to `/var/log/static-pod-recovery/`,
re-checks each is still exited, and removes it. It refuses to act unless the
exact condition is present. Run against the healthy pod afterwards, it
refused with `changed=0`.

## 5. Related finding: API VIP connection refusals

Both cilium-operator replicas crash-loop (about 800 restarts each) with
`dial tcp 10.97.3.100:6443: connect: connection refused` lasting one minute
before the operator exits. Keepalived logs show correct failover during a
planned HAProxy stop on 2026-11-20 and brief VRRP flaps at suspend/resume
times. The specific events behind the refusals **could not be correlated**,
because every log involved was stamped by a different incorrect clock. This
remains open; see section 7.

## 6. Corrective and preventive actions

The first live run of `11-time-sync.yml` stopped on the first host
without changing anything: chronyd is confined by AppArmor to
`/etc/chrony`, so it could not read Ansible's temporary file during
validation. `--check` mode does not run `validate`, so the preview did not
reveal this. The role now validates a copy placed under `/etc/chrony`.


| Action | Implementation | Status |
|---|---|---|
| Allow chrony to step large offsets at any time | `timesync` role sets `makestep 1.0 -1` (validated with `chronyd -p`) | Implemented |
| Fail the build if a host is not synchronised | `timesync` role asserts offset ≤ 0.5 s and leap status | Implemented |
| Apply to every host | `timesync` added to `01-common.yml` and `02-load-balancers.yml` | Implemented |
| Correct the live cluster safely | `11-time-sync.yml`: one host at a time, API `livez` and etcd health after each control-plane host, cluster-wide agreement check | Run 2026-11-21: all 7 hosts within 6 ms of NTP, cluster agreement within 0.86 s; second run idempotent |
| Recover a stuck static pod | `12-recover-static-pod.yml`: explicit target, refuses unless the exact condition is present, removes only stale exited containers after saving their logs | Run 2026-11-21 on tf-ha-control2: recovered without restarting the API server |
| Regression tests | `tests/test_timesync_and_recovery.py` | Implemented |

## 7. Open items

- Confirm "service account token is not valid yet" 401s stop once real
  time passes the issue time of tokens minted by fast API servers (a few
  were still logged on tf-ha-control1 shortly after the correction, as
  expected).
- With clocks corrected, correlate future cilium-operator restarts with
  keepalived and HAProxy logs to find the cause of the VIP refusals.
- Consider alerting on node clock offset (for example,
  `node_timex_offset_seconds` from node-exporter) once observability is in
  place.

## 8. Expected transient effects when correcting the clocks

- Service-account tokens issued by API servers that were about 30 minutes
  fast carry issue times in the future. After correction, API servers
  reject them as "not valid yet" until real time passes their issue time.
  The kubelet refreshes projected tokens automatically; expect intermittent
  401s for up to about 30 minutes.
- Leases renewed with future timestamps (leader election) appear valid for
  longer than intended until real time catches up.
- Stepping etcd members one at a time, checking health after each, keeps
  quorum intact.

## 9. Lessons learned

- "chrony is running" and "reachable sources" do not mean the clock is
  correct. Verification must check the actual offset.
- On VM-hosted clusters, host suspend is a fault-injection event. Clock
  discipline must handle large offsets after startup, not only at boot.
- Clock skew destroys log correlation, which is the main tool for
  diagnosing every other fault. Fix time first. Even after correction,
  `kubectl logs --since` stays unreliable for a while, because lines written
  while a node was fast carry future timestamps; use the application's own
  timestamps.
- Clock jumps can corrupt orderings that software infers from timestamps
  (here, the kubelet's choice of "latest" container). Restarts do not fix
  persisted timestamps.
- `--check` previews do not exercise `validate`; test the real apply path
  on one low-risk host first.

## 10. Environment limitations

All VMs share one physical host, so a host suspend affects every node at
once. Production failure domains would not share this failure mode.
