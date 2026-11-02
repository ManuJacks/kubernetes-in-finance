# ADR-002: Separate Infrastructure Provisioning and Configuration Management

- **Status:** Proposed
- **Date:** 2026-11-02

## Context

The platform requires repeatable infrastructure provisioning and consistent
operating-system configuration across multiple Kubernetes nodes.

The design should separate infrastructure lifecycle management from
machine configuration and Kubernetes bootstrap.

## Decision

Use Terraform for infrastructure provisioning and Ansible for
operating-system configuration.

### Terraform responsibilities

- Define virtual machine resources.
- Declare CPU, memory and disk allocations.
- Define network and zone assignments.
- Manage infrastructure lifecycle.
- Expose machine addresses and connection information.
- Support repeatable creation and destruction.

### Ansible responsibilities

- Configure operating-system prerequisites.
- Manage users and SSH access.
- Apply operating-system security settings.
- Configure kernel modules and networking prerequisites.
- Install and configure containerd.
- Apply Kubernetes node prerequisites.
- Validate configuration consistency.

### Kubernetes bootstrap

Use kubeadm for Kubernetes cluster initialization and node joining.

Kubernetes bootstrap is a distinct lifecycle responsibility.

## Alternatives considered

### Terraform only

Rejected because infrastructure provisioning and detailed machine
configuration have different responsibilities and lifecycle requirements.

### Ansible only

Rejected because Terraform provides a declarative infrastructure
provisioning model and a clear infrastructure resource lifecycle.

### Shell scripts

Useful for small tasks but insufficient as the primary configuration
management approach for this project.

## Consequences

Positive:
- Clear separation of responsibilities.
- Repeatable infrastructure and OS configuration.
- Easier troubleshooting and maintenance.
- Better opportunities for independent validation.

Trade-offs:
- Two automation technologies must be maintained.
- State and inventory information must be coordinated.
- Ordering and dependencies must be explicitly managed.

## Validation

- Provision infrastructure from a clean state.
- Reapply Terraform and verify no unintended changes.
- Run Ansible repeatedly and verify idempotency.
- Validate OS prerequisites on every Kubernetes node.
- Verify that infrastructure destruction and recreation are predictable.

## Boundaries

Terraform must not become an opaque mechanism for managing Kubernetes
workloads.

Ansible must not silently replace Kubernetes declarative workload
management.

Flux CD will manage Kubernetes desired state after cluster bootstrap.
