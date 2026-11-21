# Platform Acceptance Criteria

## Worker replacement acceptance

- [ ] Only the selected worker VM and inventory entry are changed.
- [ ] Other VMs, control-plane nodes, and worker1 remain unchanged.
- [ ] SSH access is restored with the existing public key; no private key is copied or committed.
- [ ] Kubernetes, containerd, and CNI versions are compatible with the live cluster.
- [ ] A stale Node is removed only after workload/storage assessment and explicit confirmation.
- [ ] The replacement joins and reaches `Ready`; Cilium is healthy and workloads can schedule.
- [ ] Repeating the workflow is safe: a healthy worker is not reset or rejoined.
- [ ] Any preflight, version, workload, or readiness failure stops without unrelated deletion.

## 1. Purpose

Define measurable acceptance criteria for the Kubernetes in Finance
platform.

A capability is not considered complete until its implementation,
validation evidence and known limitations are documented.

## 2. Infrastructure and High Availability

- [ ] Terraform can reproducibly provision the infrastructure.
- [ ] Ansible configuration is repeatable and idempotent.
      _Partial evidence: `11-time-sync.yml` and `02-load-balancers.yml`
      re-runs reported `changed=0` on 2026-11-21; other playbooks not yet
      re-verified._
- [x] API VIP fails over between load balancers.
      _Evidence: [game day 2026-11-21](../gameday/2026-11-21-api-availability.md), E1 and E2c._
- [x] Kubernetes API remains accessible during an individual
      load-balancer failure.
      _Evidence: [game day 2026-11-21](../gameday/2026-11-21-api-availability.md). Measured interruption 3.6 s (crash) and 5.3 s
      (HAProxy failure); zero on failback after the STP and sysctl fixes._
- [x] Three control-plane nodes maintain etcd quorum.
      _Evidence: [game day 2026-11-21](../gameday/2026-11-21-api-availability.md), E3 (quorum held on 2/3 after leader loss)._
- [x] Loss of one control-plane node does not prevent cluster
      operation.
      _Evidence: [game day 2026-11-21](../gameday/2026-11-21-api-availability.md), E3: etcd leader powered off; a full incident
      demo (deploy, diagnose, remediate, verify) passed during the outage._
- [ ] Worker failure is detected and workloads recover where
      replica capacity permits.
- [x] Every host's clock is within 0.5 s of NTP and all hosts agree
      within 5 s (`11-time-sync.yml`), including after a VM power-off and
      reboot.
      _Evidence: [incident 2026-11-21](../incidents/2026-11-21-clock-drift-after-host-suspend.md);
      api-lb1-new at 0.0 s offset after forced power-off and reboot._
- [ ] Clocks recover automatically after a desktop-host suspend/resume
      (expected from `makestep 1.0 -1`; not yet re-tested).
- [x] A control-plane static pod stuck in `CreateContainerError` with a
      reserved container name is recovered by `12-recover-static-pod.yml`
      without stopping the running container.
      _Evidence: [incident 2026-11-21](../incidents/2026-11-21-clock-drift-after-host-suspend.md), section 4._
- [x] An etcd snapshot restores successfully into an isolated data
      directory. _Evidence: [game day 2026-11-21](../gameday/2026-11-21-api-availability.md), E4._
- [ ] Full cluster recovery from an etcd snapshot (disruptive drill).
- [x] A rebooted load balancer starts HAProxy and rejoins without a
      dual-MASTER or extended outage. _Evidence: [game day 2026-11-21](../gameday/2026-11-21-api-availability.md), E2c._

## 3. Kubernetes Networking

- [x] Cilium operates on all five Kubernetes nodes.
- [x] kube-proxy replacement is enabled and verified.
- [x] Pod-to-pod connectivity works across nodes in both directions.
- [ ] Kubernetes Services route traffic correctly.
- [ ] DNS resolution works across workloads.
- [ ] Default-deny network policies are enforced.
- [ ] Network failures and Cilium agent restarts are tested.
- [ ] Hubble provides observable network flow information.

**Evidence and procedures:**

- `docs/decisions/ADR-004-networking.md`
- `docs/incidents/2026-11-05-etcd-cross-zone-nat.md`
- `docs/runbooks/network-connectivity.md`

**Current limitations:**

- The host NAT exemption is managed by an Ansible-installed
  systemd service and timer. Reboot validation passed: the
  exemption remained first in POSTROUTING and the timer
  successfully executed the reconciliation service.
- Kubernetes Service routing, DNS, NetworkPolicy enforcement,
  Hubble flow visibility and failure recovery remain untested.
- Multipass zones share one physical host and do not provide
  independent physical failure domains.

## 4. Identity and Access Security

- [ ] Kubernetes RBAC follows least-privilege principles.
- [ ] Administrative and workload identities are separated.
- [ ] Privileged operations are auditable.
- [ ] Secrets are not stored in source control.
- [ ] Credential rotation procedures are documented.
- [ ] Unauthorized access attempts are tested.

## 5. Software Supply-Chain Security

- [ ] Container images are vulnerability-scanned.
- [ ] Image provenance and origin can be established.
- [ ] Software bills of materials are generated.
- [ ] Production changes require documented review.
- [ ] Deployment artifacts are traceable to source commits.
- [ ] Rollback procedures are documented and tested.

## 6. Auditability and Change Governance

- [ ] Kubernetes API audit logging is enabled.
- [ ] Administrative actions can be attributed to identities.
- [ ] Infrastructure changes are traceable to Git commits.
- [ ] Production changes have documented authorization.
- [ ] Logs are centrally collected.
- [ ] Log retention and access controls are documented.
- [ ] Incident timelines can be reconstructed from available evidence.

## 7. Data Protection

- [ ] Data in transit is encrypted.
- [ ] Sensitive data at rest is encrypted.
- [ ] Database credentials are protected.
- [ ] Sensitive information is excluded from application logs.
- [ ] Data access follows least-privilege principles.
- [ ] Backup confidentiality and integrity are validated.

## 8. Observability and Incident Management

- [ ] Infrastructure and Kubernetes metrics are collected.
      _Partial: host metrics and API probes only; no VM or Kubernetes object
      metrics yet ([monitoring](../monitoring/README.md))._
- [x] Critical platform alerts are configured.
      _Evidence: API availability burn-rate, RPO and drill alerts, unit-tested
      with `promtool test rules` in CI ([monitoring](../monitoring/README.md))._
- [x] API endpoint availability is monitored.
      _Evidence: `/readyz` through the VIP every 10 s with TLS verification;
      99.9% / 30-day SLO ([monitoring](../monitoring/README.md))._
- [ ] Cilium network health is observable.
- [ ] Alert delivery is tested.
      _Not implemented: alerts are visible in Prometheus and Grafana but are
      not routed (no Alertmanager)._
- [x] Incident response procedures are documented.
      _Evidence: `docs/runbooks/`, `docs/incidents/`._
- [ ] Monitoring failures are detectable.
      _Partial: a missing probe and a stale backup collector raise tested
      alerts; failure of Prometheus itself is not detected._

## 9. Disaster Recovery and Resilience

- [x] etcd backup procedures are documented.
- [ ] etcd restoration is tested.
      _Partial: the isolated restore drill passes and is timed
      (`scripts/drills/etcd-restore-drill.sh`); full cluster restore not yet
      exercised._
- [ ] Application data backup and restoration are tested.
- [x] Recovery Time Objectives (RTO) are defined.
      _For load-balancer and control-plane failures; full-cluster restore RTO
      intentionally unset until timed ([monitoring](../monitoring/README.md))._
- [x] Recovery Point Objectives (RPO) are defined.
      _24 h, measured continuously from the backup store ([monitoring](../monitoring/README.md))._
- [x] Recovery exercises record actual recovery times.
      _Evidence: [game day](../gameday/2026-11-21-api-availability.md) probe measurements; restore drill duration exported
      as `platform_drill_duration_seconds`._
- [ ] Backup copies are separated from the primary failure domain.
      _Partial: snapshots are stored on the host over NFS, outside the VMs,
      but on the same physical machine._
- [x] Recovery limitations are documented.
      _Evidence: [monitoring](../monitoring/README.md) ("What this does not claim"), [game day](../gameday/2026-11-21-api-availability.md)._

**Evidence and procedures:**

- `docs/runbooks/etcd-backup-restore.md`
- `ansible/playbooks/10-etcd-backup.yml`
- `ansible/roles/etcd-backup/`

## 10. Financial Workload Integrity

- [ ] Transaction processing supports idempotent requests.
- [ ] Duplicate transaction processing is prevented.
- [ ] Committed transaction records are durable.
- [ ] Failed transactions can be safely retried.
- [ ] Transaction history is auditable.
- [ ] Workload communication is restricted through network policy.
- [ ] Application recovery does not compromise transaction integrity.

## 11. Evidence and Acceptance

Every completed criterion must have:

- Implementation reference.
- Validation procedure.
- Test result.
- Supporting evidence.
- Known limitations.

Passing an installation check alone does not establish operational
readiness or regulatory compliance.

## 12. CI/CD and Platform Lifecycle Automation

These criteria apply when GitHub Actions orchestration is implemented.
They are not acceptance criteria for the current manual and Ansible
implementation phase.

- [ ] Pull requests run automated validation without deployment permissions.
- [ ] Terraform changes produce a reviewable plan before approval-gated apply.
- [ ] Infrastructure and platform deployment workflows require appropriate authorization.
- [ ] Workflows invoke version-controlled Terraform and Ansible automation.
- [ ] Helm chart versions and configuration are pinned and reviewable.
- [ ] The self-hosted runner uses a dedicated restricted identity.
- [ ] Runner network access is limited to required platform resources.
- [ ] Deployment credentials are scoped and protected.
- [ ] Secrets never appear in workflow logs, artifacts or source control.
- [ ] Workflow records identify the commit, target, execution result and approval where applicable.
- [ ] Post-deployment validation checks API health, node readiness and Cilium health.
- [ ] Failed validation prevents promotion or reports a clear deployment failure.
- [ ] Destructive recovery operations require explicit authorization.
- [ ] Flux reconciliation is independently monitored and remains separate from CI/CD orchestration.

## 13. Platform Limitations

The initial implementation runs on a single physical host.

Multipass networking zones simulate infrastructure separation but
do not provide independent physical availability zones.

The platform is an engineering reference architecture, not a
certified or production-ready financial-services deployment.
