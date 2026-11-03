# Kubernetes in Finance
## A Financial Services Platform Engineering Blueprint

A practical reference architecture exploring how to design, build, secure,
operate and govern a resilient Kubernetes platform in a financial-services
context.

The project emphasizes architectural reasoning, infrastructure automation,
high availability, security, observability, operational resilience, change
governance and disaster recovery.

## Architecture

The platform is being developed as a repeatable, infrastructure-as-code
implementation using Multipass, Terraform, Ansible and Kubernetes.

The initial environment uses three logical network zones on a single
physical host. These zones help demonstrate failure-domain placement and
resilience patterns, but do not represent independent physical availability
zones.

See the [Platform Architecture Overview](docs/architecture/overview.md).

## Architecture Decision Records

| Decision | Document |
|---|---|
| Infrastructure environment | [ADR-001: Multipass](docs/decisions/ADR-001-multipass.md) |
| Infrastructure automation | [ADR-002: Terraform and Ansible](docs/decisions/ADR-002-terraform-ansible.md) |
| Kubernetes bootstrap | [ADR-003: Kubernetes Bootstrap](docs/decisions/ADR-003-kubernetes-bootstrap.md) |
| Networking | [ADR-004: Networking](docs/decisions/ADR-004-networking.md) |

## Engineering and Operations

- [Acceptance Criteria](docs/testing/acceptance-criteria.md)
- [Observability Strategy](docs/observability/strategy.md)
- [Alerting Policy](docs/observability/alerting-policy.md)
- [AI Engineering Governance](docs/ai-engineering/AI_ENGINEERING_GOVERNANCE.md)

## Engineering Principles

- Document architectural decisions and their trade-offs.
- Automate infrastructure and configuration wherever practical.
- Design for failure, recovery and operational verification.
- Apply least privilege and explicit security boundaries.
- Treat observability as an operational requirement.
- Preserve traceability between proposed changes, authorization,
  implementation and validation.
- Keep human accountability and approval central to AI-assisted engineering.

## Project Status

This is an evolving reference architecture. Proposed capabilities are not
considered implemented or validated until supported by implementation
evidence and documented testing.

The project does not claim production readiness or regulatory compliance.
Its purpose is to demonstrate practical engineering methods, architectural
trade-offs and evidence-based validation relevant to financial services.

## Getting Started

1. Install Multipass, Terraform, Ansible and the required SSH tooling.
2. Review the Terraform configuration and VM resource requirements.
3. Create a local Ansible inventory from the example:

   ```bash
   cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
4. Replace the example addresses and configure your SSH access.
5. Review the Terraform plan before provisioning infrastructure.

**Important:** Terraform manages the lifecycle of five Kubernetes VMs.
Running `terraform destroy` permanently deletes those managed VMs through
the Multipass provisioning script. Review the plan carefully before
applying or destroying infrastructure.

The current environment uses logical Multipass zones on one physical host.
It is a learning and validation environment, not a demonstration of
physical multi-availability-zone resilience.
