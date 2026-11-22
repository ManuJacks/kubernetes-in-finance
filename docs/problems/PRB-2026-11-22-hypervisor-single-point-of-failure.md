# PRB-2026-11-22-hypervisor-spof: one VM daemon is a single point of failure for the whole platform

Written with the production-debug Problem template. Related incident:
[INC-2026-11-22-api-outage-multipassd](../incidents/INC-2026-11-22-api-outage-multipassd.md) (Sev 1).

| Field | Value |
|---|---|
| State | Root Cause Analysis (trigger is an upstream defect, not yet reproduced) |
| Configuration item | Lab host: multipassd 1.17.2; worker resize procedure |
| Problem owner | Platform Engineering |
| Review date | 2026-11-22 |
| Known error | Yes: if multipassd exits, its restarts tear down the zone networks and cannot adopt running VMs |
| Workaround | [Runbook](../runbooks/multipassd-crash.md), `scripts/recover-multipassd.sh` |

## Summary

A planned resize of one worker asked multipassd to stop that VM, and the
daemon crashed. Its failed restarts deleted the zone networking that every
VM depends on, so a change scoped to one worker took down the whole
platform API for 12.5 minutes. A bug in our resize preflight then let the
second worker's resize start during the outage. Recovery required
power-cycling every VM. Detection worked (page in 3 min 15 s).

## Impact

See the INC: API unavailable 12.5 minutes, all VMs power-cycled, no data
lost, about 29% of the monthly error budget spent.

## Root cause and contributing factors

- **Root cause: a hidden shared dependency.** The platform's HA design
  (three control planes, two LBs, three zones) assumes failures are
  independent, but every VM, bridge, NAT rule and DHCP/DNS server depends on
  one process on one host. A failure of that process is a platform-wide
  failure. The change was risk-assessed as "one worker for two minutes".
- **Trigger: multipassd 1.17.2 crashed (SIGSEGV) on `multipass stop`.**
  Not reproduced; no core retained for this crash (three SIGABRT cores exist
  from the recovery restarts). Host memory was under pressure (5.7 GiB swap
  peak recorded for the unit), which may be relevant.
- **Amplifier: crash cleanup destroys the data plane.** Each failed restart
  deleted FORWARD/NAT rules and took the bridges down (zone3's was deleted)
  while the VMs were still running.
- **Amplifier: orphans block restart.** The previous daemon's dnsmasq held
  port 53; its QEMU processes held the disk locks. The daemon cannot adopt
  running VMs, so recovery meant a power-cut for every VM.
- **Contributing: resize preflight bug.** It required other nodes to be
  Ready but not schedulable, so a node cordoned by a failed resize counted
  as healthy; worker1 was drained during the outage. Fixed (test below).
- **Contributing: the change ran unattended.** Terraform ran both worker
  resizes as parallel provisioners and continued after the first failed;
  the lock serialized them but nothing stopped the second.

## Detection review

| Question | Answer |
|---|---|
| Did an alert fire? | Yes: `ApiAvailabilityFastBurn`, 3 min 15 s after the first failed probe |
| Right severity? | Yes: page |
| Should something have alerted earlier? | A multipassd failure is invisible to Prometheus except through its consequences. Action 5 |
| Anything misleading? | No. `EtcdBackupFailed` tickets were a true consequence |

## What went well / what was hard

- Went well: the burn-rate page fired well within its KPI on a real outage;
  the cause chain was identified from the journal within minutes; etcd came
  back consistent; every change was approved by the owner.
- Hard: three different failure messages, each hiding the next (socket,
  port 53, disk lock, missing bridges).
- Lucky: the zones were fully isolated, so etcd could not accept writes
  before the power-cut.

## Action items

| # | Type | Action | Owner | Due | Delivered by | Test / evidence | Status |
|---|---|---|---|---|---|---|---|
| 1 | Prevent | Resize preflight refuses if any other node is cordoned, not only NotReady | Platform Engineering | 2026-11-22 | `scripts/multipass-node.sh` | `tests/test_node_resize.py::test_refuses_when_another_node_is_cordoned` (fails with only the fix removed) | Done, pending merge |
| 2 | Prevent | Resizes run one worker per apply with an explicit confirmation, never as an unattended multi-node apply | Platform Engineering | 2026-11-29 | `KIF_RESIZE_CONFIRM=<node>` required; [resize runbook](../runbooks/worker-memory-resize.md) uses `-target`, one worker per apply; multipassd must be active | `test_refuses_without_confirmation_for_this_node` (unset and wrong node) | Done, pending merge |
| 3 | Mitigate | Recovery runbook and script for a crashed multipassd | Platform Engineering | 2026-11-22 | [Runbook](../runbooks/multipassd-crash.md), `scripts/recover-multipassd.sh` | Used (in its one-off form) to recover this incident | Done, pending merge |
| 4 | Prevent | Report the crash upstream (Multipass 1.17.2: SIGSEGV on stop; SIGABRT on restart with orphaned processes); test whether a guest-initiated shutdown avoids the stop path | Platform Engineering | 2026-12-06 | Upstream issue; the resize now powers off from inside the guest and never calls `multipass stop` (`test_never_uses_multipass_stop`) | Resize one worker via guest shutdown without daemon crash | In progress: both workers resized via guest poweroff (18:28, 18:32 UTC) without a daemon error; two runs are evidence, not proof. `multipass info` briefly failed (`ssh connection failed`) while the guest powered off; the script's polling tolerated it. Upstream report open |
| 5 | Detect | Alert on the multipassd unit failing (node-exporter systemd collector on the host) | Platform Engineering | 2026-12-06 | Future CHG with `promtool` test | Stop the unit in a drill; alert within 2 minutes | Open |
| 6 | Process | Any change touching the hypervisor or host networking is risk-assessed as **platform-wide** (High), with a fresh etcd snapshot first and the owner watching | Platform Engineering | 2026-11-22 | ADR or change policy update | Next such CHG records it | Open |
| 7 | Prevent | Long term: remove the single host as a shared dependency (second host, or bare-metal/cloud nodes); until then, document it in the architecture as an accepted single point of failure | Platform Engineering | 2027-Q1 | ADR | ADR accepted | Open |

## Closure criteria

Actions 1–3 merged; 4–6 delivered or deferred with dates; 7 recorded as an
accepted risk in an ADR. The worker resize (PRB-2026-11-22-node-memory,
action 3) is not retried until actions 1 and 2 are done.
