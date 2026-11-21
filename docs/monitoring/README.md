# Monitoring: SLO, RPO and RTO evidence

Prometheus and Grafana run on the engineering host, outside the cluster.
They measure what a client of the platform experiences and whether the
platform could be recovered.

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook ansible/playbooks/13-monitoring.yml
```

| Service | Address (localhost only) |
|---|---|
| Grafana | http://127.0.0.1:3000 (user `admin`; password in `~/.local/share/kubernetes-in-finance/monitoring/secrets/grafana-admin-password`) |
| Prometheus | http://127.0.0.1:9090 |

No sudo is required; the user must be in the `docker` group. The play
verifies that every scrape target is up and every rule loaded.

## What is measured

| Objective | Measurement | Alerting |
|---|---|---|
| **API availability SLO**: 99.9% over 30 days | `/readyz` probed through the VIP every 10 s, with TLS verified against the cluster CA | Multi-window burn rate: 14.4x (1 h and 5 m) and 6x (6 h and 30 m) page; 1x (3 d and 6 h) raises a ticket |
| **RPO**: at most 24 h of etcd data loss | Age of the newest snapshot in the NFS backup store (`/srv/k8s-etcd-backups`), using file modification time | Ticket at 26 h; page if the store is empty; ticket if the collector stops reporting |
| **RTO evidence** | `scripts/drills/etcd-restore-drill.sh`: timed isolated restore of the newest snapshot | Ticket if the last drill failed or none ran in 30 days |

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
| Data loss (any failure requiring etcd restore) | **RPO 24 h** | Newest snapshot age (continuous) | `EtcdBackupRPOAtRisk`, dashboard |
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
- **Alerts are not routed.** They appear in Prometheus and Grafana; there is
  no Alertmanager or paging integration.
- **The 30-day SLO window began when monitoring was deployed** (2026-11-21).
  Until 30 days of data exist, the "30 d" figures cover a shorter period.
- **Single probe location.** The probe runs on the same host as the VMs, so it
  cannot distinguish a host network problem from a platform outage.
- **Host monitoring stops if the host does.** This is deliberate (see below)
  but is a single point of failure for observability.

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
