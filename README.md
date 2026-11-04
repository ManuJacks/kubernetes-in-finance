# Kubernetes in Finance

## A Financial Services Platform Engineering Blueprint

A hands-on platform engineering project exploring how to design, provision,
secure, operate and validate a resilient Kubernetes platform in a
financial-services context.

The project demonstrates engineering judgement across infrastructure
automation, high availability, security, observability, operational
resilience, change governance and disaster recovery.

## Architecture

The environment is being built with Multipass, Terraform and Ansible.

- **Multipass:** local virtual infrastructure and simulated network zones.
- **Terraform:** virtual machine lifecycle management.
- **Ansible:** operating system, Kubernetes node and load-balancer configuration.
- **Kubernetes / kubeadm:** planned cluster bootstrap and orchestration.
- **HAProxy:** TCP load balancing for the Kubernetes API endpoint.
- **Keepalived:** VRRP-based high availability for the API virtual IP.
- **Cilium:** proposed cluster networking, subject to validation.
- **Flux CD:** planned GitOps reconciliation.

### Target topology

Three control-plane nodes and two worker nodes across three logical network
zones, supported by two load-balancer VMs. HAProxy forwards Kubernetes API
traffic to the control-plane nodes. Keepalived manages the shared API virtual
IP (10.97.3.100) using VRRP.

All virtual machines share one physical Linux host. The zones help explore
placement and failure-domain concepts; they are not independent physical
availability zones.

The existing load balancers are configured through Ansible. VIP failover
has been demonstrated by stopping Keepalived on the active node and
observing the standby node acquire the virtual IP. End-to-end Kubernetes
API availability and traffic forwarding remain to be validated.

See the [Platform Architecture Overview](docs/architecture/overview.md).

## Engineering Workstreams

| Area | Focus |
|---|---|
| Infrastructure | Repeatable provisioning and configuration |
| Kubernetes and HA | Cluster lifecycle, API availability and failure testing |
| Security | Least privilege, trust boundaries and secrets |
| Delivery | Controlled changes and GitOps reconciliation |
| Observability | Metrics, alerting and operational visibility |
| Recovery | Failure scenarios, recovery procedures and evidence |
| Governance | Architecture decisions, acceptance criteria and traceability |
| AI-assisted engineering | Human authorization and evidence-based validation |

## Architecture Decision Records

| Decision | Document |
|---|---|
| Infrastructure environment | [ADR-001: Multipass](docs/decisions/ADR-001-multipass.md) |
| Infrastructure automation | [ADR-002: Terraform and Ansible](docs/decisions/ADR-002-terraform-ansible.md) |
| Kubernetes bootstrap | [ADR-003: Kubernetes Bootstrap](docs/decisions/ADR-003-kubernetes-bootstrap.md) |
| Networking | [ADR-004: Networking](docs/decisions/ADR-004-networking.md) |

## Engineering Standards and Governance

- [Architecture Principles](ARCHITECTURE_PRINCIPLES.md)
- [Project Charter](PROJECT_CHARTER.md)
- [Governance Model](GOVERNANCE_MODEL.md)
- [Acceptance Criteria](docs/testing/acceptance-criteria.md)
- [Observability Strategy](docs/observability/strategy.md)
- [Alerting Policy](docs/observability/alerting-policy.md)
- [AI Engineering Governance](docs/ai-engineering/AI_ENGINEERING_GOVERNANCE.md)

## Getting Started

### Prerequisites

Linux host, Multipass, Terraform 1.6+, Ansible, SSH client and key pair.

### Provision virtual machines

From the repository root:

```bash
cd terraform
terraform init
terraform validate
terraform plan
```

Review the plan before running `terraform apply`. Terraform manages five
Kubernetes VMs through the Multipass provisioning script. The two existing
load balancers are recorded in Terraform configuration but are not managed
through its VM lifecycle. Additional load-balancer provisioning requires
an explicit configuration request.

### Configure Ansible

Return to the repository root and create a local inventory:

```bash
cd ..
cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
```

Replace the example addresses with actual VM addresses and configure the
SSH private-key path. The local `hosts.yml` is excluded from version control.

### Validate connectivity and playbook syntax

From the repository root:

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ansible -i ansible/inventory/hosts.yml kubernetes -m ping
```

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/01-common.yml --syntax-check
```

The common playbook prepares the nodes. The load-balancer playbook configures
HAProxy and Keepalived on the existing load-balancer VMs:

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/02-load-balancers.yml
```

**Destructive operation warning:** `terraform destroy` deletes the five
Terraform-managed VMs through the Multipass provisioning script. Review
Terraform actions carefully before applying or destroying infrastructure.

## Project Status and Limitations

This is an evolving reference architecture. Capabilities are not considered
implemented or validated until supported by implementation evidence and
documented testing. This project does not claim production readiness or
regulatory compliance.

- All VMs share one physical host and failure domain.
- Multipass zones simulate separation; they are not physical availability zones.
- Local testing does not establish cloud-scale networking or resilience.
- Compute and memory constrain workload and monitoring capacity.
- Kubernetes bootstrap, Cilium networking and Flux reconciliation remain
  subject to implementation and validation.
- HAProxy TCP forwarding is configured, but end-to-end Kubernetes API
  availability has not yet been demonstrated.
- VRRP VIP failover has been tested between the two existing load balancers.

## Engineering Principles

- Document architectural decisions, alternatives and trade-offs.
- Automate infrastructure and configuration wherever practical.
- Design for failure, recovery and operational verification.
- Apply least privilege and explicit security boundaries.
- Treat observability as an operational requirement.
- Define measurable acceptance criteria and retain validation evidence.
- Preserve traceability between proposed changes, authorization,
  implementation and validation.
- Keep human accountability central to AI-assisted engineering.

### Human Judgment in AI-Assisted Engineering

AI can accelerate technical investigation, generate diagnostic
commands, and interpret system behaviour. However, technical
fluency does not guarantee situational awareness or sound
engineering judgment.

Effective engineering requires human oversight to:
- Maintain awareness of the overall architecture and project lifecycle.
- Challenge assumptions and recognize when an investigation is premature.
- Distinguish symptoms from root causes.
- Prioritize work according to dependencies and project objectives.
- Validate AI-generated recommendations against actual system state.

**Example from this project:** During load-balancer configuration,
AI pursued increasingly detailed HAProxy diagnostics before
recognizing that Kubernetes had not yet been initialized.
Human intervention identified the sequencing problem and
redirected the investigation.

**Engineering principle:** AI should augment engineering
judgment, not replace it.

**AI proposes. Evidence challenges. Humans authorize. Automation executes.
Validation confirms.**
