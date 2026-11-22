# INC-2026-11-22: Platform API unavailable after multipassd crashed during a worker resize

Written with the production-debug Incident template. Root cause and
prevention: [PRB-2026-11-22-hypervisor-spof](../problems/PRB-2026-11-22-hypervisor-single-point-of-failure.md).

| Field | Value |
|---|---|
| State | Resolved |
| Short description | Kubernetes API unavailable: all VMs disconnected after the VM daemon crashed |
| Configuration item | Lab host: multipassd 1.17.2 (snap rev 20750); all platform VMs |
| Assignment group | Platform Engineering |
| Impact | **1 - High**: the platform API, and therefore every tenant's ability to deploy or change anything, was unavailable |
| Urgency | **1 - High**: unavailable, no workaround |
| Priority | **1 - Critical (Sev 1)** by the severity matrix. Lab platform: no customers or business services exist; the rating describes what the same failure would mean for the platform's users |
| Detected by | `ApiAvailabilityFastBurn` (page), firing 18:07:45 UTC |
| Caused by | A planned change: in-place worker memory resize (`terraform apply`, PRB-2026-11-22-node-memory action 3) |
| Resolution code | Workaround: hard-stopped orphaned VM processes and restarted the daemon; VMs restarted by the daemon |

## Description (business impact)

For 12.5 minutes (18:04:30 to 18:17:00 UTC, 76 failed probes through the
VIP) no client could reach the Kubernetes API. Running pods on each node
continued, but nodes could not reach each other or the API. Every VM was
then power-cycled by the recovery. etcd lost no data (all members on the
same raft index afterwards). Error budget consumed: about 12.5 of the
43 minutes per 30 days.

## Work notes (UTC)

| Time | Observation or action | Classification | Source |
|---|---|---|---|
| ~18:03 | Owner applies the reviewed plan (5 add, 5 change, 0 destroy). Control-plane resize steps no-op. Both worker resizes queue on the lock | action | Terraform output |
| ~18:03 | worker2: cordoned and drained | fact | Terraform output |
| 18:04:20 | `multipass stop tf-ha-worker2`: **multipassd crashes (SIGSEGV)**; its dnsmasq (running since Nov 19) survives | fact | systemd journal |
| 18:04:20–18:05:55 | 5 restart attempts: each fails `dnsmasq died ... port 53` and, on exit, deletes the zone FORWARD/NAT rules; systemd stops retrying | fact | journal |
| 18:04:30 | First failed API probe through the VIP | fact | `probe_success` |
| ~18:04 | Resize script exits leaving worker2 cordoned; lock released; **worker1's resize passes preflight** (checked Ready, not schedulable) and starts draining | fact | Terraform output; script |
| ~18:05 | worker1 drain fails: API `EOF`; worker1 left cordoned; `kube-state-metrics` evicted with nowhere to run | fact | Terraform output |
| 18:05:33 | Engaged | action | Responder |
| 18:07:45 | `ApiAvailabilityFastBurn` firing (3 min 15 s after first failure) | fact | `ALERTS` |
| ~18:08 | Diagnosis: orphaned dnsmasq holds port 53 on 10.97.{0,1,2}.1 | fact | `ss`, `ps`, journal |
| ~18:10 | Owner kills dnsmasq, restarts daemon: now fails `Failed to get shared "write" lock` on `api-lb2-new`'s image (orphaned QEMU) | action / fact | journal |
| ~18:12 | Zone bridges: zone1 and zone2 `DOWN`, **zone3 deleted**; taps detached; SSH to every VM fails | fact | `ip -br addr` |
| ~18:13 | Decision: hard-stop orphaned QEMU (zones isolated since 18:04, no etcd quorum, no writes) and restart daemon | hypothesis / decision | Responder, owner |
| ~18:15–18:17 | Recovery script: 7 QEMU processes stopped (workers, control planes, LBs); daemon started (3 SIGABRT core dumps 18:15:36–18:16:06, then running); bridges rebuilt; daemon restarts all previously running VMs | action / fact | Script output; `coredumpctl` |
| 18:17:00 | Last failed probe | fact | `probe_success` |
| 18:19:09 | API 200 via VIP; all nodes Ready | fact | `curl`, `kubectl` |
| 18:19:20 | Clocks within 3 ms of NTP on all 7 hosts; etcd 3 members, raft term 22, index 1886880 applied on all | fact | `chronyc`, `etcdctl` |
| 18:19:25 | Both workers uncordoned; evicted pods Running by 18:19:34 | action / fact | `kubectl` |
| 18:19 | `EtcdBackupFailed` on all control planes for the outage window (NFS store unreachable) | fact | `ALERTS` |

**Key intervals.** Time to detect: 3 min 15 s (KPI 9, ≤ 5 min: met, first
real measurement). Time to recover service: 12 min 30 s.

## Related records

- Problem: [PRB-2026-11-22-hypervisor-spof](../problems/PRB-2026-11-22-hypervisor-single-point-of-failure.md)
- Change that triggered it: in-place worker resize (`terraform_data.node_memory`); workers remain at 1 GiB
- Runbook written from this incident: [multipassd crash](../runbooks/multipassd-crash.md)
