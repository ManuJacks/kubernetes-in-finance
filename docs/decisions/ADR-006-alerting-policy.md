# ADR-006: Alerting policy: what pages, what raises a ticket

- **Status:** Proposed (for review)
- **Date:** 2026-11-22

## Context

The platform has 35 alerts (9 pages) across the API SLO, etcd backups, recovery drills,
the alerting pipeline, node resources and (since kube-state-metrics) workload
state. They reach one person through ntfy: `page` at urgent priority,
repeating every 4 hours; `ticket` at default priority, repeating daily.

Without a written policy, severity drifts towards "everything pages", and
pages that are not actionable teach the on-call person to ignore them. The
first alert review (2026-11-22) found exactly that risk: an API SLO page
caused by the monitoring host waking from suspend, not by the platform.

## Decision

### 1. A page means a human must act now

An alert pages only if it meets at least one of these:

1. **Users are affected now, or the error budget is burning fast.** SLO
   burn-rate alerts (symptoms), not their causes.
2. **Data loss or unrecoverable state is imminent.** RPO breached, an empty
   backup store, a disk or node memory about to run out.
3. **Redundancy is gone.** A lost node: the next failure is an outage.
4. **Resource exhaustion has started.** An OOM kill (see 2).

Everything else is a **ticket**: needs a human within a working day.

Page and ticket describe how urgently an *alert* needs a human. They are
not incident severity: a responder opens an incident (INC) only if there is
impact, and derives its Sev 1–5 from impact × urgency (production-debug
`docs/procedures/SEVERITY_MATRIX.md`). A page can lead to no incident (a
false page, recorded as a Problem) and a ticket can lead to a Sev 3.
Causes whose symptoms already page (a crash-looping pod behind a healthy
SLO), degraded-but-redundant states, and blind spots in monitoring itself
(the alert that the alerts cannot work) are tickets.

### 2. OOM kills page

Workers have about 950 MiB each and container memory limits are
overcommitted (131% on `tf-ha-worker1` on 2026-11-22). An OOM kill is the
first visible sign that memory is exhausted; the next steps are node memory
pressure, kubelet evictions and a NotReady node. On this platform, resource
problems are investigated immediately, so `KubeContainerOOMKilled` pages.

*Alternative considered:* a ticket, as for other single-container failures.
Rejected: by the time a daily ticket is read, the node may be evicting pods.

*Cost:* an OOM in an unimportant workload also pages. The alert review
(section 6) counts these. If OOM pages turn out mostly non-actionable, scope
the page to platform namespaces and make the rest tickets.

### 3. Every alert is tested and has a runbook

- A `promtool` test proves it fires, and where a false positive is plausible
  (failover blips, old OOMs, short crash loops, scrape gaps), a test proves
  it does **not**.
- A `runbook` annotation points at a document that exists.
- `for` durations are longer than known transients: the 5.3 s load-balancer
  failover measured on 2026-11-21 does not page.

`tests/test_monitoring.py` enforces all three, and that this ADR's inventory
matches the rules.

### 4. Insufficient data must not page

An alert computed from a nearly empty window measures the monitoring, not the
platform. Burn-rate pages require each long window to contain at least half
its expected samples. The trade-off: after Prometheus itself has a gap (host
suspend), fast-burn paging resumes once 30 minutes of probe data exist.
A full outage in that window is still visible on the dashboard and pages
within 30 minutes.

Monitoring blind spots get their own tickets instead
(`ApiAvailabilityProbeAbsent`, `KubeStateMetricsDown`,
`EtcdBackupCollectorStale`).

### 5. One failure, one page

Alertmanager inhibit rules suppress alerts that a firing page already
explains:

| While firing | Suppressed |
|---|---|
| `ApiAvailabilityFastBurn` | `ApiAvailabilitySlowBurn` |
| `EtcdBackupMissing` | `EtcdBackupRPOAtRisk` |
| `KubeNodeNotReady` | `KubePodStuckPending`, `KubeDeploymentReplicasUnavailable`, `KubeStatefulSetReplicasUnavailable`, `KubeDaemonSetPodsUnavailable` |

The node-loss rule is cluster-wide because those alerts have no node label.
An unrelated controller failure during a node outage stays hidden until the
node recovers; it reappears then.

### 6. Alerts are reviewed every two weeks

`scripts/alerting/alert_review.py` lists what fired. Every page is classified
actionable or not; each non-actionable page leads to a change (threshold,
severity, inhibit, or deletion) recorded in the review. Process:
[alert review](../monitoring/alert-review.md).

## Alert inventory

| Alert | Severity | Why this severity |
|---|---|---|
| `ApiAvailabilityFastBurn` | page | Users affected: 2% of the 30-day budget per hour |
| `ApiAvailabilitySlowBurn` | page | Users affected: 5% of the budget in 6 hours |
| `ApiAvailabilityBudgetErosion` | ticket | Slow erosion over 3 days; no immediate harm |
| `ApiAvailabilityProbeAbsent` | ticket | Monitoring blind spot |
| `EtcdBackupRPOAtRisk` | page | Data-loss objective already breached |
| `EtcdBackupMissing` | page | No restore possible |
| `EtcdBackupFailed` | ticket | One failed attempt; the next is within an hour and RPO still holds |
| `EtcdBackupNodeStale` | ticket | Other nodes still back up |
| `EtcdBackupCollectorStale` | ticket | Monitoring blind spot |
| `PlatformDrillFailed` | ticket | Recovery evidence, not a live failure |
| `PlatformDrillOverdue` | ticket | Recovery evidence is stale |
| `WorkloadRecoveryDrillFailed` | ticket | Recovery evidence, not a live failure |
| `WorkloadRecoveryObjectiveMissed` | ticket | Recovery evidence, not a live failure |
| `NodeLossAlertNotVerified` | ticket | A page may be broken, but nothing is failing now |
| `WorkloadRecoveryDrillOverdue` | ticket | Recovery evidence is stale |
| `AlertmanagerDown` | ticket | Cannot page about itself; visible in Grafana |
| `AlertNotificationsFailing` | ticket | Delivery degraded; visible in Grafana |
| `KubeStateMetricsDown` | ticket | Monitoring blind spot |
| `KubeNodeNotReady` | page | Redundancy gone; the next failure is an outage |
| `KubeContainerOOMKilled` | page | Resource exhaustion has started (section 2) |
| `KubePodCrashLooping` | ticket | Cause; user impact pages through the SLO |
| `KubeContainerImagePullFailing` | ticket | Usually a bad deploy; the old ReplicaSet keeps serving |
| `KubeContainerConfigError` | ticket | Usually a bad deploy; the old ReplicaSet keeps serving |
| `KubePodStuckPending` | ticket | Capacity or scheduling; not user-facing yet |
| `KubeDeploymentReplicasUnavailable` | ticket | Degraded but serving |
| `KubeStatefulSetReplicasUnavailable` | ticket | Degraded but serving |
| `KubeDaemonSetPodsUnavailable` | ticket | One node affected; urgent for Cilium (runbook) |
| `KubeJobFailed` | ticket | Batch work; retry is not time-critical |
| `KubePersistentVolumeClaimPending` | ticket | No StorageClass yet; expected until one exists |
| `NodeMemoryPressureWarning` | ticket | Headroom shrinking |
| `NodeMemoryPressureCritical` | page | OOM evictions imminent |
| `NodeCpuHighUtilizationWarning` | ticket | Headroom shrinking |
| `NodeCpuSaturatedCritical` | page | Control-plane starvation risk |
| `NodeDiskSpaceFillingFast` | ticket | Headroom shrinking |
| `NodeDiskSpaceCritical` | page | Disk exhaustion imminent; etcd and kubelet stop |
| `VaultSealed` | page | Every workload login and secret read fails until a human unseals |
| `VaultUnavailable` | page | Same impact as sealed; the cause differs |
| `VaultProbeAbsent` | ticket | Monitoring gap, no impact yet |
| `VaultCertificateExpiringSoon` | ticket | Two weeks to rotate; impact only at expiry |

## Consequences

- Five pages can reach the phone from workload and resource state, in
  addition to the SLO and RPO pages. The review measures whether that is
  sustainable for one person.
- New alerts cannot merge without a test, a runbook and an inventory entry.
- `ntfy` remains best-effort, with no escalation or acknowledgement
  ([monitoring](../monitoring/README.md)); this policy decides what is
  urgent, not how reliably it is delivered.
