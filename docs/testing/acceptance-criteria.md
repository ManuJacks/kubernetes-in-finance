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

- [ ] Cilium operates on all Kubernetes nodes.
- [ ] kube-proxy replacement is enabled and verified.
- [ ] Pod-to-pod connectivity works across nodes.
- [ ] Kubernetes Services route traffic correctly.
- [ ] DNS resolution works across workloads.
- [ ] Default-deny network policies are enforced.
- [ ] Network failures and Cilium agent restarts are tested.
- [ ] Hubble provides observable network flow information.

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

## 12. Platform Limitations

The initial implementation runs on a single physical host.

Multipass networking zones simulate infrastructure separation but
do not provide independent physical availability zones.

The platform is an engineering reference architecture, not a
certified or production-ready financial-services deployment.
