# Platform Acceptance Criteria

## 1. Purpose

Define measurable acceptance criteria for the Kubernetes in Finance
platform.

A capability is not considered complete until its implementation,
validation evidence and known limitations are documented.

## 2. Infrastructure and High Availability

- [ ] Terraform can reproducibly provision the infrastructure.
- [ ] Ansible configuration is repeatable and idempotent.
- [ ] API VIP fails over between load balancers.
- [ ] Kubernetes API remains accessible during an individual
      load-balancer failure.
- [ ] Three control-plane nodes maintain etcd quorum.
- [ ] Loss of one control-plane node does not prevent cluster
      operation.
- [ ] Worker failure is detected and workloads recover where
      replica capacity permits.

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
- [ ] Critical platform alerts are configured.
- [ ] API endpoint availability is monitored.
- [ ] Cilium network health is observable.
- [ ] Alert delivery is tested.
- [ ] Incident response procedures are documented.
- [ ] Monitoring failures are detectable.

## 9. Disaster Recovery and Resilience

- [ ] etcd backup procedures are documented.
- [ ] etcd restoration is tested.
- [ ] Application data backup and restoration are tested.
- [ ] Recovery Time Objectives (RTO) are defined.
- [ ] Recovery Point Objectives (RPO) are defined.
- [ ] Recovery exercises record actual recovery times.
- [ ] Backup copies are separated from the primary failure domain.
- [ ] Recovery limitations are documented.

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
