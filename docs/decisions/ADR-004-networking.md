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

Initial network validation confirms that each zone uses a separate
Layer 2 Linux bridge and /24 subnet. The Multipass host routes traffic
between these networks. Cross-zone ICMP and TCP/HTTP connectivity have
been demonstrated.

These are routed network segments, not a shared Layer 2 broadcast domain.

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

1. **Complete:** Inspect Multipass zone interfaces, bridges and routes.
2. **Complete:** Verify cross-zone ICMP connectivity.
3. **Complete:** Verify cross-zone TCP/HTTP connectivity from zone1 and
   zone3 to a test HTTP server in zone2.
4. **Complete:** Confirm that zones use separate Layer 2 bridges and
   that the host routes between their subnets.
5. **Pending:** Test the proposed VIP mechanism and its failure behaviour.
6. **Pending:** Verify API endpoint reachability and control-plane failover.
7. **Pending:** Verify etcd peer connectivity.
8. **Pending:** Validate Cilium pod networking.
9. **Pending:** Validate Kubernetes Service routing.
10. **Pending:** Test NetworkPolicy enforcement and record packet paths.

## Limitations

All zones share one physical host.

Network segmentation in this lab is not equivalent to independent
physical availability zones or cloud network failure domains.


## Observed network validation

Test environment:

| Zone | Subnet | Test VM | Address |
|---|---|---|---|
| zone1 | 10.97.0.0/24 | netcheck-z1 | 10.97.0.200 |
| zone2 | 10.97.1.0/24 | netcheck-z2 | 10.97.1.22 |
| zone3 | 10.97.2.0/24 | netcheck-z3 | 10.97.2.181 |

The test VMs use their respective zone gateway addresses:
10.97.0.1, 10.97.1.1 and 10.97.2.1.

A Python HTTP server was started on netcheck-z2, listening on
0.0.0.0:8080. Requests from netcheck-z1 and netcheck-z3 both completed
successfully and returned HTTP 200.

Observed route behaviour from zone1 to zone2 uses the zone1 gateway
(10.97.0.1), rather than direct Layer 2 neighbour resolution of the
zone2 VM. The Multipass host has IPv4 forwarding enabled.

This validates routed cross-zone application connectivity in the
current lab configuration. It does not establish independent zone
failure domains, production-grade firewall controls, or VIP failover.

The host remains a shared routing and physical failure dependency.
