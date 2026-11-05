# Financial Services Platform Roadmap

## Purpose

Build a reproducible, highly available Kubernetes platform that
demonstrates the engineering controls, operational resilience and
evidence practices expected in a financial-services environment.

This is an engineering reference implementation, not a claim of
regulatory compliance or a production banking platform.

## Delivery principles

- Design controls into the platform rather than document them afterward.
- Make security, resilience and change governance testable.
- Preserve traceability from approved change to deployed state.
- Record evidence for both successful operation and failure recovery.
- Distinguish simulated infrastructure boundaries from real failure domains.

## Roadmap

### 1. Infrastructure foundation

- [x] Provision infrastructure reproducibly through Terraform.
- [x] Apply repeatable VM configuration through Ansible.
- [x] Provision isolated Multipass network zones.
- [x] Provision three control-plane and two worker VMs.
- [x] Deploy dedicated HAProxy load balancers.
- [x] Validate Keepalived VIP failover.
- [ ] Document infrastructure recovery procedures.

### 2. Highly available Kubernetes

- [ ] Bootstrap three control-plane nodes with stacked etcd.
- [ ] Join two worker nodes.
- [ ] Route the Kubernetes API through the load-balancer VIP.
- [ ] Validate control-plane and etcd health.
- [ ] Test control-plane failure and recovery.

### 3. Networking and traffic control

- [ ] Deploy Cilium with eBPF kube-proxy replacement.
- [ ] Validate pod-to-pod and cross-node connectivity.
- [ ] Validate Kubernetes Service routing and DNS.
- [ ] Implement default-deny network policies.
- [ ] Introduce Hubble for network flow visibility.
- [ ] Test network component failure and recovery.

#### Next milestone: Kubernetes Service routing and DNS

- [ ] Deploy a temporary test workload and ClusterIP Service.
- [ ] Verify Service endpoints and cross-node connectivity.
- [ ] Verify in-cluster DNS resolution, including cross-namespace lookups.
- [ ] Capture Cilium and Hubble evidence where available.
- [ ] Test Service and DNS recovery after relevant component restarts.
- [ ] Record results in acceptance criteria and the networking runbook.

**Starting state:** Cilium 1.20.4 is deployed with kube-proxy
replacement. All five nodes are Ready, CoreDNS is Running, and
bidirectional cross-node pod HTTP connectivity is validated.

**Constraints:** Do not change the CNI architecture or introduce
additional networking components for this milestone. Validate
the existing deployment first.

### 4. Observability and operations

- [ ] Establish centralized log collection.
- [ ] Deploy Prometheus and Alertmanager.
- [ ] Deploy Grafana, Node Exporter and kube-state-metrics.
- [ ] Monitor control-plane, node, workload and critical service health.
- [ ] Define actionable alerts, severity and response expectations.
- [ ] Create operational dashboards and incident runbooks.
- [ ] Document observability limitations and monitoring failure modes.

### 5. Security foundation

- [ ] Define least-privilege Kubernetes RBAC.
- [ ] Separate platform administration from workload identities.
- [ ] Establish secret handling and rotation practices.
- [ ] Enforce workload security standards.
- [ ] Scan container images and dependencies.
- [ ] Generate and retain software bills of materials.
- [ ] Establish image provenance and deployment verification.

### 6. Financial-services control practices

- [ ] Protect audit logs through documented retention and access controls.
- [ ] Map relevant OSFI guidance to demonstrable engineering controls.
- [ ] Establish auditable change approval and production promotion.
- [ ] Demonstrate separation of duties.
- [ ] Enable and protect Kubernetes audit evidence.
- [ ] Record deployment identity, approval and release history.
- [ ] Document third-party and software supply-chain risks.
- [ ] Define evidence retention and access expectations.

### 7. Resilience and disaster recovery

- [ ] Define workload recovery objectives (RTO and RPO).
- [ ] Back up etcd and document backup protection.
- [ ] Back up required application and platform state.
- [ ] Demonstrate restoration from backup.
- [ ] Test node, control-plane and networking failures.
- [ ] Record recovery times, data integrity and remaining limitations.

### 8. Financial reference workload

- [ ] Deploy a representative transaction-processing service.
- [ ] Demonstrate idempotent request handling.
- [ ] Prevent duplicate transaction processing.
- [ ] Preserve committed transaction integrity during retries and failures.
- [ ] Demonstrate auditable transaction history.
- [ ] Apply sensitive-data logging and access controls.

### 9. Evidence and operational handover

- [ ] Maintain architecture diagrams and decision records.
- [ ] Publish reproducible build and deployment instructions.
- [ ] Maintain failure-injection and recovery test results.
- [ ] Document known limitations and outstanding risks.
- [ ] Provide runbooks for common operational scenarios.
- [ ] Link validation evidence to acceptance criteria.

### 10. CI/CD and platform lifecycle automation

**Status: Planned — implement after the initial HA Kubernetes platform is operational.**

- [ ] Introduce GitHub Actions as the controlled workflow orchestration layer.
- [ ] Implement Terraform plan and approval-gated apply workflows.
- [ ] Implement Ansible host configuration and platform deployment workflows.
- [ ] Automate Helm-based Cilium installation and configuration.
- [ ] Automate controlled Kubernetes control-plane and worker expansion.
- [ ] Implement automated platform health and acceptance validation.
- [ ] Introduce a secured self-hosted runner for access to the private Multipass network.
- [ ] Enforce protected branches, workflow permissions and deployment approvals.
- [ ] Protect deployment credentials and prevent secrets from entering logs or artifacts.
- [ ] Retain workflow execution history and deployment evidence.
- [ ] Evaluate Flux for continuous reconciliation of Kubernetes workloads, complementary to CI/CD orchestration.

## External control references

The implementation will consider relevant guidance, including:

- OSFI B-13: Technology and Cyber Risk Management.
- OSFI B-10: Third-Party Risk Management.
- OSFI E-21: Operational Risk Management and Resilience.

These references inform design and control mapping. Implementing
selected technical controls does not establish regulatory compliance.

## Scope boundaries

The initial implementation runs on one physical host. Multipass
network zones simulate segmentation and fault separation; they
are not independent physical availability zones.

The financial reference workload demonstrates platform controls
and transaction-processing concepts. It is not a real financial
system and will not process real customer data or money.
