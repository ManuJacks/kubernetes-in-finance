# INC-2026-11-22: tf-ha-worker2 NotReady (memory exhaustion)

Written with the production-debug Incident template
(`docs/procedures/INCIDENT_RECORD_TEMPLATE.md` in
[production-debug](https://github.com/ManuJacks/production-debug)). Root
cause and prevention: [PRB-2026-11-22-node-memory](../problems/PRB-2026-11-22-node-memory-exhaustion.md).

| Field | Value |
|---|---|
| State | Resolved |
| Short description | tf-ha-worker2 NotReady: node unresponsive |
| Configuration item | tf-ha-worker2 (Kubernetes worker) |
| Assignment group | Platform Engineering |
| Impact | **2 - Medium**: the platform lost one of its two workers; every tenant lost workload redundancy, and pods on the node were evicted (metrics-server, so `kubectl top` failed) |
| Urgency | **2 - Medium**: degraded, workaround in place (workloads rescheduled to tf-ha-worker1) |
| Priority | **3 - Moderate (Sev 3)**, from the [severity matrix](https://github.com/ManuJacks/production-debug/blob/main/docs/procedures/SEVERITY_MATRIX.md) ("one of two workers lost, all services serving") |
| Detected by | `KubeNodeNotReady` (page), firing 17:36:00 UTC |
| Resolution code | Workaround: stopped the background process starving the node; removed leftover files held in RAM |

## Description (business impact)

No business services run on this lab platform. Platform impact: for
18 minutes the cluster ran on one worker, so any further worker failure
would have stopped every workload. The API SLO was unaffected (control
plane healthy).

## Work notes (UTC)

| Time | Observation or action | Classification | Source |
|---|---|---|---|
| 17:29:01 | `apt-daily.service` starts (systemd timer), followed by `apt-news`, `esm-cache`, PackageKit and `apt-check` | fact | worker2 journal |
| 17:29:16 | Last kubelet heartbeat | fact | Node `Ready` condition |
| 17:30:08 | Node condition `Ready=Unknown` (NodeStatusUnknown) | fact | Node conditions |
| 17:31:00 | `KubeNodeNotReady` pending | fact | Prometheus `ALERTS` |
| 17:36:00 | `KubeNodeNotReady` firing; page delivered to ntfy | fact | `ALERTS`; Alertmanager notifications (1 sent, 0 failed) |
| ~17:41 | DaemonSet tickets (`cilium`, `cilium-envoy`) firing; suppressed by the node-loss inhibit rule while the page fires | fact | Prometheus; Alertmanager |
| 17:42 | Engaged. Node: 950 MiB, no swap, 1 vCPU; **55 MiB available**; 99% system CPU; ~2.1 GB/s disk reads (page-cache thrashing); load 13; CRI calls `DeadlineExceeded` | fact | `free`, `vmstat`, kubelet journal |
| 17:42 | `apt-check` (PID 23837, ~100 MiB RSS) running since 17:29:04 | fact | `ps` |
| 17:44 | Hypothesis: the apt run exhausted memory; confirm by stopping it | hypothesis | Responder |
| 17:46:57 | Emergency change (approved by owner): `kill 23837` | action | Responder |
| 17:47:15 | Node `Ready`; still thrashing (68 MiB available) | fact | Node conditions, `free` |
| 17:47:20 | `/tmp` is tmpfs and holds **187 MiB** of installer archives left by Ansible on 2026-11-20 (containerd, crictl, etcd-tools) | fact | `df`, `du` |
| 17:47:45 | `KubeNodeNotReady` resolved | fact | `ALERTS` |
| 17:47:54 | Removed the three installer directories: 264 MiB available; disk reads 44 MB/s | action / fact | Responder; `free`, `vmstat` |
| 17:48:42 | DaemonSet tickets active (node recovered before its pods): inhibit window ended before the symptoms did | fact | Alertmanager |
| 17:48:52 | `cilium`, `cilium-envoy` 5/5 available | fact | `kubectl get ds` |
| 17:50:26 | CHG: node hygiene applied to all 5 nodes (apt timers, unattended upgrades, login MOTD apt scripts disabled); re-run idempotent | action | `01-common.yml --tags node-hygiene` |
| 17:50:54 | worker2: 360 MiB available, load 1.2; all nodes Ready | fact | `free`, `uptime`, `kubectl get nodes` |

**Key intervals.** Time to detect (heartbeat lost to page firing): 6 min 44 s.
Time to mitigate (page to node Ready): 11 min 15 s. Total NotReady:
about 17 minutes.

## Evidence

Collected from the host and nodes with read-only commands during the
incident; quoted in the work notes. No evidence bundle (the node-level
evidence is outside `k8s_evidence.sh`'s namespace scope).

## Related records

- Problem: [PRB-2026-11-22-node-memory](../problems/PRB-2026-11-22-node-memory-exhaustion.md)
- Changes: emergency process kill and file removal on tf-ha-worker2 (owner
  approved, 17:46 and 17:47); node hygiene on all nodes (17:50, Ansible
  `node-hygiene` tag, this branch)
