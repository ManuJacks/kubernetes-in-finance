# ADR-004: Kubernetes and Infrastructure Networking

- **Status:** Accepted — infrastructure networking and Kubernetes API endpoint deployed; core pod networking validated; Service routing and NetworkPolicy validation pending
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

Cilium 1.20.4 is the deployed Kubernetes CNI.

Networking responsibilities are separated into:

1. Infrastructure networking: Multipass networks and host routing.
2. API endpoint networking: dedicated HAProxy and Keepalived load balancers.
3. Pod networking: Cilium-managed connectivity and network policy.
4. Service networking: Kubernetes Service virtual IPs and traffic routing remains the responsibility, but validation is still pending.

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

HAProxy has been installed and configured through Ansible.

**Not yet validated:** HAProxy runtime health checks against the
Kubernetes API servers, API reachability through the VIP, and
control-plane failure and recovery.

The intended Kubernetes controlPlaneEndpoint is 10.97.3.100:6443.

The VIP is hosted by the dedicated load-balancer pair, not by the
control-plane nodes.

## Cilium and kube-proxy replacement

**Decision:** Cilium 1.20.4 provides Kubernetes pod networking,
network policy enforcement and eBPF-based Service load balancing.

kube-proxy will not be installed. Cilium will operate in
kube-proxy replacement mode.

Rationale:

- Use a modern eBPF-based Kubernetes networking datapath.
- Avoid maintaining separate kube-proxy and Cilium Service
  implementations.
- Provide integrated network policy and flow observability.
- Establish a foundation for Hubble network monitoring.

Implementation requirements:

- Pin a stable Cilium release compatible with Kubernetes 1.36.6.
- Configure kubeadm to skip the kube-proxy installation phase.
- Configure Cilium to use the correct node interfaces and addresses.
- Preserve API connectivity through 10.97.3.100:6443.
- Validate Service routing, DNS and cross-node pod connectivity.
- Test Cilium agent failure and recovery.

The migration and rollback implications of changing the CNI
must be documented before implementation.

Hubble will be introduced after core networking is operational.

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
capabilities than the deployed Cilium design.

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
- Network policy and flow observability through the deployed CNI.
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
7. **Complete:** Deploy HAProxy configuration through Ansible.
8. **Complete:** Configure Kubernetes API access through the VIP and verify API readiness after host reboot.
9. **Complete:** Validate control-plane and etcd peer connectivity across zones, including all three etcd endpoints committing proposals after host reboot.
10. **Complete:** Validate Cilium pod networking and bidirectional cross-node pod HTTP connectivity.
11. **Complete:** Validate VXLAN transport and preservation of original node source addresses.
12. **Complete:** Deploy Ansible-managed host NAT exemption reconciliation and verify idempotency, rule ordering and persistence after host reboot.
13. **Pending:** Validate Kubernetes Service routing.
14. **Pending:** Validate cluster DNS resolution.
15. **Pending:** Test NetworkPolicy enforcement and record packet paths.
16. **Pending:** Test Cilium agent, control-plane and load-balancer failure and recovery scenarios.
17. **Pending:** Validate Hubble flow visibility for representative pod traffic.

## Limitations

All zones and load balancers share one physical host.
Network segmentation does not provide independent physical availability
zones or cloud network failure domains.

VIP failover and post-reboot API readiness have been validated.
End-to-end API availability during load-balancer and control-plane
failures remains to be tested.

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
