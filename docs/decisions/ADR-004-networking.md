# ADR-004: Kubernetes and Infrastructure Networking

- **Status:** Proposed
- **Date:** 2026-11-02

## Context

The platform requires connectivity between virtual machines, Kubernetes
control-plane nodes, worker nodes, pods, services and external clients.

Networking must support a highly available Kubernetes API endpoint,
cross-node workload communication, service discovery and network security.

Multipass currently exposes three separate zone subnets:

- zone1: 10.97.0.0/24
- zone2: 10.97.1.0/24
- zone3: 10.97.2.0/24

The actual routing and Layer 2 relationships between these networks must
be verified.

## Decision

Cilium is the proposed Kubernetes CNI.

The design separates four networking responsibilities:

1. Infrastructure networking: Multipass virtual networks and host routing.
2. Kubernetes control-plane networking: API server endpoint and etcd
   communication.
3. Pod networking: Cilium-managed pod connectivity and network policy.
4. Service networking: Kubernetes Service virtual IPs and traffic routing.

## Control-plane endpoint

The intended design requires a stable Kubernetes API endpoint.

HAProxy is the proposed API load balancer.

Keepalived is a candidate for providing a virtual IP through failover.

However, the VIP mechanism is not yet approved.

The separate Multipass zone subnets may prevent a conventional shared
Layer 2 VRRP arrangement from working across all three control-plane nodes.

We will validate the available network capabilities before selecting
the final VIP architecture.

## Cilium

Cilium will provide:

- Pod addressing and cross-node connectivity.
- Kubernetes network policy enforcement.
- Visibility into network flows.
- Optional eBPF-based service handling, subject to a separate decision.

Kube-proxy replacement will not be enabled by default.

It must be justified and validated independently.

## Required connectivity

The architecture must account for:

- Control-plane to control-plane communication.
- etcd peer and client communication.
- Control-plane to worker communication.
- Worker-to-worker communication.
- Pod-to-pod communication.
- Pod-to-Service communication.
- DNS resolution.
- Administrator access to the Kubernetes API.
- External access to selected application services.

Firewall and routing requirements must be documented.

## Alternatives considered

### Flannel

A simpler CNI, but offers fewer integrated network policy and
observability capabilities than the proposed Cilium design.

### Calico

A capable alternative with mature routing and network policy features.
Retained as a valid alternative if Cilium resource or networking
constraints become problematic.

### Cloud-managed networking

Not selected for the local implementation because the project must
demonstrate the underlying networking responsibilities.

## Consequences

Positive:
- Clear separation of networking layers.
- Network policy and flow observability.
- Opportunity to evaluate eBPF-based networking.
- Practical troubleshooting across infrastructure and Kubernetes layers.

Trade-offs:
- Additional resource consumption.
- More complex troubleshooting.
- Local virtual network behaviour may differ from cloud networking.

## Validation

Before approving the final implementation:

1. Inspect all Multipass zone interfaces and routes.
2. Verify VM-to-VM connectivity within and between zones.
3. Determine whether the zones share a Layer 2 broadcast domain.
4. Test the proposed VIP mechanism.
5. Verify API endpoint reachability and failover.
6. Verify etcd peer connectivity.
7. Validate Cilium pod networking.
8. Validate Kubernetes Service routing.
9. Test NetworkPolicy enforcement.
10. Record observed packet paths and failure behaviour.

## Limitations

All zones share one physical host.

Network segmentation in this lab is not equivalent to independent
physical availability zones or cloud network failure domains.
