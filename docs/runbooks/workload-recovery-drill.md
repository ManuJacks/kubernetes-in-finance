# Runbook: Workload recovery drill (KPI 5)

**Objective:** after an unplanned worker loss, a replicated workload is back
at full capacity within **6 minutes**, with Kubernetes default settings.

The 6 minutes is derived, not chosen: about 40 s for the node controller to
mark the node NotReady, the default 300 s `not-ready`/`unreachable`
toleration before eviction, and about 20 s to schedule and start the
replacement. The drill tests whether that holds on this cluster.

## What the drill does

`scripts/drills/workload-recovery-drill.sh [worker]` (default `tf-ha-worker2`):

1. **Preflight.** Refuses unless every node is Ready and the target is a
   worker. It deploys `kubernetes/drills/workload-recovery.yaml` (namespace
   `kif-drill`, two small nginx replicas with preferred anti-affinity) and
   checks one replica is on the target node.
2. **Inject.** `multipass stop --force <worker>`: power-off, no graceful
   shutdown, as in the game day.
3. **Measure**, polling once per second, from the moment of power-off:
   | Phase | Meaning |
   |---|---|
   | `node_notready` | The node controller marked the node NotReady |
   | `endpoint_removed` | The replica on the lost node is no longer Ready, so Services stop sending it traffic. **Before this, about half of requests to the workload fail.** |
   | `recovered` | Two Ready replicas on surviving nodes: **the KPI** |
   | `alert_firing` | `KubeNodeNotReady` is firing in Prometheus: time to detect a node loss |
4. **Restore.** Starts the worker again (always, also on failure or Ctrl-C),
   waits for it to be Ready and deletes the `kif-drill` namespace.
5. **Record.** Writes textfile metrics (`drill="workload_node_loss"`):
   `platform_drill_last_success`, `platform_drill_duration_seconds`,
   `platform_drill_phase_seconds{phase=...}` and
   `platform_drill_alert_fired`.

The node stays down until the page fires (at most 10 minutes,
`ALERT_WAIT`), because recovery (about 345 s) normally completes before the
page (5 minutes after NotReady, about 370 s).

## Running it

Monthly, by hand (it is disruptive by design, so it has no timer):

```bash
scripts/drills/workload-recovery-drill.sh tf-ha-worker2
```

- Every non-DaemonSet pod on the worker is evicted to the other worker.
  Check the survivor has memory headroom first (`kubectl top nodes`).
- `KubeNodeNotReady` **will page** your phone. That is part of the test.
  Alertmanager suppresses the Pending-pod and replica tickets it causes
  (inhibit rule, [ADR-006](../decisions/ADR-006-alerting-policy.md)).
- Pick the worker that is *not* running kube-state-metrics, or the drill
  measures nothing while kube-state-metrics is rescheduled:
  `kubectl -n kube-system get pod -l app.kubernetes.io/name=kube-state-metrics -o wide`.

Record each run in the table below and update KPI 5 in
[monitoring](../monitoring/README.md) and the Grafana KPI panel.

## Results

| Date | Worker | NotReady | Endpoint removed | Recovered (KPI ≤ 360 s) | Page firing | Notes |
|---|---|---|---|---|---|---|
| — | — | — | — | — | — | First run pending |

## Alerts

| Alert | Meaning | Action |
|---|---|---|
| `WorkloadRecoveryDrillFailed` | Capacity not restored within 15 minutes | Read the drill output; check the surviving worker for Pending pods (`kubectl get pods -A --field-selector status.phase=Pending`) and its memory |
| `WorkloadRecoveryObjectiveMissed` | Recovered, but in more than 6 minutes | Compare phases with the previous run: slow NotReady points at the node controller; a slow `recovered` after eviction points at scheduling or image pulls |
| `NodeLossAlertNotVerified` | The node-loss page did not fire | Treat as a broken page: check `KubeNodeNotReady` in Prometheus, kube-state-metrics, and Alertmanager delivery (`scripts/alerting/verify-delivery.sh page`) |
| `WorkloadRecoveryDrillOverdue` | No drill in 35 days | Run the drill |

## What this does not show

- **Stateless workloads only.** A StatefulSet with a volume on the lost node
  behaves differently: the replacement cannot start until the volume is
  released, which with node-local storage means until the node returns.
- **Partial failure before eviction.** Between power-off and
  `endpoint_removed` (about 40 s), a Service still routes to the dead
  replica. Reducing that needs readiness-aware clients or a faster node
  monitor grace period, not a faster eviction.
- **Faster recovery is possible but deliberately not configured.** Shorter
  `tolerationSeconds` on critical workloads would reduce the 300 s wait. It
  also evicts pods during short network blips. Change it only with drill
  evidence that the trade is worth it.
