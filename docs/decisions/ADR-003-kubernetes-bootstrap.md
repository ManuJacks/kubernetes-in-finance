# ADR-003: Use kubeadm for Kubernetes Bootstrap

- **Status:** Proposed
- **Date:** 2026-11-02

## Context

The project requires a reproducible Kubernetes cluster that exposes the
underlying control-plane architecture and operational responsibilities.

The platform should demonstrate cluster initialization, control-plane
membership, worker joining, certificate management and recovery.

## Decision

Use kubeadm to initialize and manage the initial Kubernetes cluster.

Use three control-plane nodes with stacked etcd and two worker nodes.

Use a stable API endpoint through the selected load-balancing architecture.

## Responsibilities

### Terraform
Provisions the virtual machines and infrastructure.

### Ansible
Prepares the operating systems, container runtime and Kubernetes
prerequisites.

### kubeadm
Initializes the cluster, establishes control-plane membership and joins
additional nodes.

### Cilium
Provides pod networking and network policy capabilities.

### Flux CD
Manages Kubernetes workload desired state after bootstrap.

## Alternatives considered

### Managed Kubernetes

Not selected because the project needs to demonstrate control-plane
architecture and operational responsibilities directly.

### Single-node Kubernetes distributions

Not selected because they abstract away too much of the HA control-plane
and bootstrap process.

### Manual Kubernetes installation

Not selected as the primary approach because kubeadm provides a
standardized and repeatable bootstrap workflow.

## Consequences

Positive:
- Explicit control over cluster initialization.
- Demonstrable HA control-plane architecture.
- Standard Kubernetes bootstrap tooling.
- Useful operational and troubleshooting experience.

Trade-offs:
- Greater operational responsibility.
- Certificate and etcd lifecycle management must be understood.
- Upgrades and recovery require deliberate procedures.

## Validation

- Initialize the first control-plane node.
- Join the remaining control-plane nodes.
- Verify three-member etcd health and quorum.
- Join both workers.
- Verify node readiness.
- Validate API availability during individual control-plane failures.
- Test etcd backup and restoration.
- Document certificate lifecycle and recovery procedures.

## Version management

Kubernetes, kubeadm, kubelet and kubectl versions must be explicitly
managed and compatibility verified.

The project must not rely on unpinned package versions for reproducibility.

## Limitations

The local five-node deployment demonstrates Kubernetes HA mechanisms
but does not establish genuine physical or cloud-zone resilience.
