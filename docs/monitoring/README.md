# Monitoring: SLO, RPO and RTO evidence

Prometheus, Alertmanager and Grafana run on the engineering host, outside the
cluster.
They measure what a client of the platform experiences and whether the
platform could be recovered.

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook ansible/playbooks/13-monitoring.yml
```

| Service | Address (localhost only) |
|---|---|
| Grafana | http://127.0.0.1:3000 (user `admin`; password in `~/.local/share/kubernetes-in-finance/monitoring/secrets/grafana-admin-password`) |
| Prometheus | http://127.0.0.1:9090 |
| Alertmanager | http://127.0.0.1:9093 |

No sudo is required; the user must be in the `docker` group. The play
verifies that every scrape target is up, every rule loaded and Prometheus is
connected to Alertmanager. It also installs the weekly restore drill as a
user systemd timer (`systemctl --user list-timers kif-restore-drill.timer`).

## Recovery KPIs

Chosen 2026-11-21 from common Kubernetes platform practice and this lab's
measured results. They are lab objectives, not production commitments. The
Grafana dashboard shows the same table with live values.

| # | KPI | Target | Measurement | Status |
|---|---|---|---|---|
| 1 | etcd RPO | ≤ 1 h | Age of the newest snapshot, continuous | Live; pages at 90 min |
| 2 | Backup success | 100% of attempts | Per-node outcome of every hourly backup | Live; ticket on any failure, or no attempt for 2 h |
| 3 | Restore drill freshness | Successful drill within 7 days | Weekly isolated restore drill (user timer, Sundays 03:00) | Live; ticket at 8 days |
| 4 | Control-plane failover RTO | LB 30 s; control-plane node 60 s | Game-day drills | Demonstrated 2026-11-21 (3.6 s, 5.3 s, no full outage) |
| 5 | Workload recovery | ≤ 6 min | — | **Defined, unmeasured** |
| 6 | Control-plane node replacement | ≤ 30 min | — | **Defined, unmeasured** |
| 7 | Full cluster restore RTO | ≤ 2 h | — | **Defined, unmeasured** (isolated restore only) |
| 8 | API availability SLO | 99.9% over 30 days | `/readyz` through the VIP every 10 s | Live; burn-rate alerts |
| 9 | Mean time to detect (full API outage) | ≤ 5 min | `promtool` test: fast-burn alert firing within 5 min of outage start | Tested in CI; delivery to ntfy verified (~35 s) |

KPIs 5–7 are listed so they are not mistaken for achieved ones. Each becomes
"demonstrated" only after a timed drill.

MTTD is the time to a firing alert. Time to a phone notification adds
Alertmanager `group_wait` (30 s) and ntfy delivery.

## What is measured

| Objective | Measurement | Alerting |
|---|---|---|
| **API availability SLO**: 99.9% over 30 days | `/readyz` probed through the VIP every 10 s, with TLS verified against the cluster CA | Multi-window burn rate: 14.4x (1 h and 5 m) and 6x (6 h and 30 m) page; 1x (3 d and 6 h) raises a ticket |
| **RPO**: at most 1 h of etcd data loss | Age of the newest snapshot in the NFS backup store (`/srv/k8s-etcd-backups`), using file modification time | Page at 90 min; page if the store is empty; ticket if the collector stops reporting |
| **Backup success** | Per-node status file written by every backup attempt | Ticket if a node's last attempt failed, or it has not attempted for 2 h |
| **RTO evidence** | `scripts/drills/etcd-restore-drill.sh`: timed isolated restore of the newest snapshot, weekly | Ticket if the last drill failed or none ran in 8 days |
| **Alerting pipeline** | Alertmanager reachability and failed-delivery counter | Ticket (visible in Grafana even when delivery is broken) |

Each API server is also probed directly (bypassing HAProxy). That is
diagnostic, not part of the SLO.

Rules are unit-tested with `promtool test rules`
(`monitoring/prometheus/tests/rules.test.yml`), including cases that must
*not* alert, such as a 4-second failover blip.

## Recovery objectives

Set 2026-11-21 from measured game-day results, with headroom. They describe
this lab platform, not a commitment for production.

| Failure | Objective | Observed | Evidence |
|---|---|---|---|
| Data loss (any failure requiring etcd restore) | **RPO 1 h** | Newest snapshot age (continuous) | `EtcdBackupRPOAtRisk`, dashboard |
| One load balancer fails | **RTO 30 s** | 3.6 s (crash), 5.3 s (HAProxy failure) | [Game day](../gameday/2026-11-21-api-availability.md) E1, E2c |
| One control-plane node fails | **RTO 60 s** | No full outage; 16 s of partial failure | Game day E3 |
| Full cluster restore from snapshot | **Not set** | Not yet exercised | Isolated restore only (1.9 s): drill metrics |

The full-cluster RTO is deliberately undefined until a full restore drill has
been timed; an objective without evidence would be a guess.

## What this does not claim

- **RTO is not measured continuously.** It is demonstrated by drills. The
  restore drill measures restoring a snapshot (1.9 s on 2026-11-21), which is
  one component of recovery, not a full cluster rebuild. Failover times
  observed in the [game day](../gameday/2026-11-21-api-availability.md) are
  lab measurements, not guarantees.
- **ntfy is not a paging system.** It has no escalation, acknowledgement or
  on-call rotation, and the public ntfy.sh service is best-effort. Anyone who
  learns the topic name can read the alerts and post fake ones.
- **Prometheus failing is not detected.** Nothing outside the host notices if
  Prometheus or the whole host stops. That needs an external dead man's
  switch (for example healthchecks.io), not yet configured.
- **The 30-day SLO window began when monitoring was deployed** (2026-11-21).
  Until 30 days of data exist, the "30 d" figures cover a shorter period.
- **Single probe location.** The probe runs on the same host as the VMs, so it
  cannot distinguish a host network problem from a platform outage.
- **Host monitoring stops if the host does.** This is deliberate (see below)
  but is a single point of failure for observability.

## Alert delivery (ntfy)

Alertmanager routes `severity=page` alerts to ntfy at **urgent** priority
(repeats every 4 h) and `severity=ticket` alerts at **default** priority
(repeats daily). ntfy formats the payload with its built-in `alertmanager`
template. Two inhibit rules prevent duplicate pages.

The topic is generated on first deploy and stored outside the repository in
`~/.local/share/kubernetes-in-finance/monitoring/secrets/ntfy-topic`. The
Alertmanager configuration only references files (`url_file`), and a test
fails if a webhook URL is ever committed.

To receive alerts on a phone, install the ntfy app and subscribe to
`kif-<contents of the ntfy-topic file>` on `ntfy.sh`. Do not paste the topic
anywhere public: it is the credential.

Verify delivery end to end (injects a synthetic alert into Alertmanager and
confirms ntfy received it; it resolves after 2 minutes):

```bash
scripts/alerting/verify-delivery.sh page
scripts/alerting/verify-delivery.sh ticket
```

CI checks the configuration (`amtool check-config`) and the routing
(`monitoring/alertmanager/tests/routes.sh`), including that an alert with no
severity still reaches a receiver.

## Why outside the cluster

An availability SLO cannot be measured from inside the system it measures:
when the control plane fails, in-cluster Prometheus fails with it and cannot
record the outage. The availability probe should stay outside the cluster's
failure domain even after the rest of the stack moves in.

Today the workers also lack capacity (950 MiB each, 173–460 MiB free on
2026-11-21) and the cluster has no StorageClass, so in-cluster Prometheus
data would not persist.

## Migration path into the cluster

The configuration in `monitoring/` (scrape config, rules, rule tests,
dashboards) is deployment-independent.

1. **Add worker memory, safely.** Do not just change `memory` in
   `terraform/main.tf`: it is part of `triggers_replace`, so Terraform would
   **destroy and recreate** each worker rather than resize it. Implement an
   in-place resize first (`multipass stop`, `multipass set
   local.<name>.memory=<size>`, `multipass start`, one worker at a time, with
   the node drained), and change Terraform so memory changes run that resize
   instead of replacing the VM.
2. **Add persistent storage** (for example a local-path provisioner) so
   Prometheus data survives pod restarts.
3. **Deploy Prometheus and Grafana in-cluster** from the same rules and
   dashboards (for example as ConfigMaps for a Helm-based stack), and add
   in-cluster exporters (kube-state-metrics, node-exporter DaemonSet).
4. **Keep the external probe.** Retain the blackbox probe of the VIP on the
   host (or another external location) as the SLO's source of truth.
