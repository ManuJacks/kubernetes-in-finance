# ADR-004: Kubernetes and Infrastructure Networking

- **Status:** Proposed — infrastructure VIP mechanism validated; Kubernetes API path pending
- **Date:** 2026-11-02

## Context

The platform requires connectivity between virtual machines, Kubernetes
control-plane nodes, worker nodes, pods, services and external clients.

Multipass provides three separate routed zone networks:

- zone1: 10.97.0.0/24
- zone2: 10.97.1.0/24
- zone3: 10.97.2.0/24

Cross-zone ICMP and TCP/HTTP connectivity have been demonstrated.
Each zone uses a separate Layer 2 bridge, with the host routing between
the subnets. These networks are not a shared Layer 2 broadcast domain.

## Decision

Cilium remains the proposed Kubernetes CNI.

Networking responsibilities are separated into:

1. Infrastructure networking: Multipass networks and host routing.
2. API endpoint networking: dedicated HAProxy and Keepalived load balancers.
3. Pod networking: proposed Cilium-managed connectivity and network policy.
4. Service networking: Kubernetes Service virtual IPs and traffic routing.

## Control-plane endpoint and load balancers

The design uses a dedicated load-balancer pair connected to a separate
frontend network.

| Component | Address |
|---|---|
| Frontend bridge | br-api-frontend |
| Frontend subnet | 10.97.3.0/24 |
| LB1 frontend | 10.97.3.11 |
| LB2 frontend | 10.97.3.12 |
| API virtual IP | 10.97.3.100 |

Keepalived 2.3.4 provides VRRPv3 virtual IP failover between the two
load balancers.

**Validated:** VRRP and ARP behaviour on the frontend bridge. The VIP
successfully moved to LB2 when Keepalived stopped on LB1, then returned
to LB1 when its Keepalived service restarted.

**Not yet validated:** HAProxy configuration, API server health checks,
Kubernetes API reachability through the VIP, and control-plane failure
and recovery.

The intended Kubernetes controlPlaneEndpoint is 10.97.3.100:6443.

The VIP is hosted by the dedicated load-balancer pair, not by the
control-plane nodes.

## Cilium

Cilium remains the proposed CNI and is expected to provide:

- Pod addressing and cross-node connectivity.
- Kubernetes network policy enforcement.
- Network flow visibility.
- Optional eBPF-based service handling, subject to a separate decision.

Kube-proxy replacement will not be enabled by default. It requires
independent justification and validation.

## Required connectivity

The architecture must account for:

- Control-plane and etcd communication.
- Control-plane to worker communication.
- Worker-to-worker communication.
- Pod-to-pod and pod-to-Service communication.
- DNS resolution.
- Administrator access to the Kubernetes API.
- External access to selected application services.

Firewall and routing requirements must be documented.

## Alternatives considered

### Flannel

Simpler, but offers fewer integrated network policy and observability
capabilities than the proposed Cilium design.

### Calico

A capable alternative with mature routing and network policy features.
Retained if Cilium resource or networking constraints become problematic.

### Cloud-managed networking

Not selected for the local implementation because the project must
demonstrate underlying networking responsibilities.

## Consequences

Positive:
- Clear separation of networking layers.
- Dedicated API load-balancer redundancy.
- Network policy and flow observability through the proposed CNI.
- Practical troubleshooting across infrastructure and Kubernetes layers.

Trade-offs:
- Additional resource consumption.
- More complex troubleshooting.
- Local virtual network behaviour may differ from cloud networking.
- The frontend bridge and load balancers remain dependencies.

## Validation

1. **Complete:** Inspect Multipass zone interfaces, bridges and routes.
2. **Complete:** Verify cross-zone ICMP connectivity.
3. **Complete:** Verify cross-zone TCP/HTTP connectivity.
4. **Complete:** Confirm separate zone Layer 2 bridges and host routing.
5. **Complete:** Validate frontend bridge VRRP and ARP behaviour.
6. **Complete:** Test VIP failover and recovery between dedicated load balancers.
7. **Pending:** Install and configure HAProxy.
8. **Pending:** Verify API server health checks and API reachability through the VIP.
9. **Pending:** Test control-plane and etcd connectivity and failure behaviour.
10. **Pending:** Validate Cilium pod networking and Kubernetes Service routing.
11. **Pending:** Test NetworkPolicy enforcement and record packet paths.

## Limitations

All zones and load balancers share one physical host.
Network segmentation does not provide independent physical availability
zones or cloud network failure domains.

The successful VIP test demonstrates load-balancer address failover,
not end-to-end Kubernetes API high availability.

## Observed network validation

Cross-zone tests used dedicated test VMs in each zone. A Python HTTP
server on netcheck-z2 (10.97.1.22:8080) returned HTTP 200 to requests
from zone1 and zone3.

Traffic from zone1 to zone2 used the zone1 gateway (10.97.0.1), rather
than direct Layer 2 neighbour resolution. The Multipass host has IPv4
forwarding enabled.

This demonstrates routed cross-zone application connectivity in the
current lab configuration. It does not establish production-grade
firewall controls or independent zone failure domains.
