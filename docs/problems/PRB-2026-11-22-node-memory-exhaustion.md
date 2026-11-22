# PRB-2026-11-22-node-memory: worker nodes have no memory margin for background activity

Written with the production-debug Problem template. Related incident:
[INC-2026-11-22](../incidents/INC-2026-11-22-worker2-memory-exhaustion.md) (Sev 3).

| Field | Value |
|---|---|
| State | Fix in Progress (actions 1, 2, 3, 9 done) |
| Configuration item | Kubernetes worker nodes (tf-ha-worker1, tf-ha-worker2) |
| Problem owner | Platform Engineering |
| Review date | 2026-11-22 |
| Known error | Yes: a ~100 MiB background process can make a 950 MiB worker unresponsive |
| Workaround | Disable background apt on nodes (done); keep `/tmp` free of persistent files (done) |

## Summary

A daily apt timer started a package check that used about 100 MiB on a
worker that already had about 190 MiB of RAM held by forgotten installer
files in `/tmp` (tmpfs). With no swap and one vCPU, the node thrashed the
page cache, the kubelet and containerd stopped responding, and the node went
NotReady for about 17 minutes. The platform survived on one worker.

## Impact

See the INC. One of two workers unavailable for about 17 minutes; pods
evicted and rescheduled; `kubectl top` unavailable while metrics-server
moved. API SLO unaffected.

## Timeline

In the [INC work notes](../incidents/INC-2026-11-22-worker2-memory-exhaustion.md#work-notes-utc).
Earlier warning sign: worker2's kernel log shows a global OOM kill on
2026-11-21 (a user `systemd` process), one day after the node was rebuilt.

## Root cause and contributing factors

- **Root cause:** worker memory (950 MiB, no swap) has no margin for
  ordinary OS background work. Here, `apt-daily.timer` started an apt
  update and `apt-check` (17:29:01; kubelet's last heartbeat 17:29:16).
- **Contributing: memory leaked into tmpfs.** The `containerd`, `crictl`
  and `etcd-tools` roles download archives into `/tmp`, which is tmpfs on
  these nodes, and never remove them. On worker2 (rebuilt 2026-11-20, not
  rebooted since) that held 187 MiB, about 20% of the node. Other nodes had
  rebooted, clearing theirs, which is why only worker2 failed.
- **Contributing: the kubelet could not protect itself.** It was starved
  by system processes, not pods, so neither eviction (default 100 Mi) nor
  a system reservation would have helped. (Kubelet reservations were
  considered and rejected for this reason.)
- **Contributing: etcd tools are installed on workers**, which do not run
  etcd (82 MiB of the leaked files).

**5 whys.** NotReady ← kubelet heartbeat stopped ← CRI calls timed out
under thrashing ← no free memory ← apt run on top of 187 MiB in tmpfs ←
installer roles assume `/tmp` is disk, and nodes ship with background apt.

## Detection review

| Question | Answer |
|---|---|
| Did an alert fire? | Yes: `KubeNodeNotReady` paged 6 min 44 s after the last heartbeat. First real measurement of node-loss detection |
| Right severity? | Yes: lost redundancy pages (ADR-006) |
| Should something have alerted earlier? | Yes. Worker2 ran with ~120 MiB available for over a day, and `NodeMemoryPressureWarning` never evaluated for **any** cluster node: its cAdvisor branch subtracted series with different label sets, which matches nothing (introduced in commit bce6083; its tests covered only the host branch). Fixed in this change with a test using the real label sets (verified to fail on the old rule). Even fixed, it would not have fired: root-cgroup working set read 509 MiB (54%) at 17:20 while available memory was ~120 MiB, because tmpfs and page cache are not counted the same way. See actions 5 and 9 |
| Anything misleading? | The DaemonSet tickets became active after the node recovered: the inhibit rule only covers the time the node page fires. See action 6 |

## What went well / what was hard

- Went well: the page arrived; the node-loss inhibit suppressed duplicate
  tickets while it fired; the cause was found with read-only commands
  before any change; the owner approved each change.
- Hard: the first mitigation (stopping apt-check) restored Ready but not
  health; the second cause was only visible by checking where memory was
  held (shared memory, then tmpfs).
- Lucky: worker1 had headroom for the evicted pods.

## Action items

| # | Type | Action | Owner | Due | Delivered by | Test / evidence | Status |
|---|---|---|---|---|---|---|---|
| 1 | Prevent | Disable apt timers, unattended upgrades and login MOTD apt scripts on cluster nodes; patch deliberately via Ansible | Platform Engineering | 2026-11-22 | `roles/common` (`node-hygiene` tag), applied 17:50 UTC | `tests/test_node_hygiene.py`; re-run changed nothing; `apt-daily.timer` disabled on all 5 nodes | Done, pending merge |
| 2 | Prevent | Installer downloads go to `/var/cache/kubernetes-in-finance/` (disk), not tmpfs `/tmp` | Platform Engineering | 2026-11-22 | `containerd`, `crictl`, `etcd-tools`, `kubernetes` roles | `tests/test_node_hygiene.py` fails on any role writing under `/tmp` (it found the fourth case) | Done, pending merge |
| 3 | Prevent | Resize workers in place (memory) without Terraform replacing the VMs; prerequisite for the Jenkins scenario | Platform Engineering | 2026-12-06 | `terraform_data.node_memory` + `multipass-node.sh resize` (workers to 1536M); `terraform plan`: 5 to add, 5 to change, **0 to destroy** | `tests/test_node_resize.py` (stubs; refusal paths and step order); workload recovery drill after resize | First attempt failed (multipassd crash, Sev 1 [INC](../incidents/INC-2026-11-22-api-outage-multipassd.md)). Retried with per-node confirmation and guest poweroff: **both workers at 1.5 GiB** (worker2 ~18:28, worker1 ~18:32 UTC, 22 s); no failed API probes, neither node NotReady; `terraform plan`: no changes | Done, pending merge |
| 4 | Process | Patching policy now that nodes do not self-update: monthly Ansible patch run, one node at a time | Platform Engineering | 2026-12-06 | Future CHG | First patch run recorded | Open |
| 5 | Detect | Node memory from the node's view (node-exporter on the nodes, or kubelet `node_memory` metrics), alerting on low *available* memory including tmpfs | Platform Engineering | 2026-12-06 | Future CHG | Replay: fill tmpfs on a test node; alert fires | Open |
| 6 | Detect | Keep DaemonSet and replica tickets quiet for a short settling period after a node recovers | Platform Engineering | 2026-12-06 | Future CHG with `promtool` test | Replay this timeline: no ticket after recovery | Open |
| 7 | Prevent | Do not install etcd tools on workers | Platform Engineering | 2026-12-06 | `01-common.yml` host targeting | Workers have no `etcdctl` | Open |
| 8 | Prevent | Apply node hygiene to the load balancers (`02-load-balancers.yml` does not include `common`) | Platform Engineering | 2026-11-29 | Future CHG | apt timers disabled on both LBs | Open |
| 9 | Detect | Fix the cluster-node memory alert expression (label mismatch) and test it with cAdvisor-shaped series | Platform Engineering | 2026-11-22 | `rules/resource-limits.yml` | `promtool` test fails on the old rule, passes on the new | Done, pending merge |

## Closure criteria

Actions 1 and 2 merged; 3–8 delivered or explicitly deferred with a date.
The trade-off in action 1 (no automatic security updates) is accepted only
together with action 4.
