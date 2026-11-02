# Platform Architecture Overview

## 1. Purpose

Describe the proposed logical architecture for Kubernetes in Finance.

This document establishes the architecture baseline. Implementation details
remain subject to validation and Architecture Decision Records.

## 2. Infrastructure constraints

- One Linux Mint physical host.
- AMD Ryzen 5 3600X, 6 physical cores and 12 threads.
- 16 GB physical memory.
- Multipass 1.17 using QEMU.
- Three available Multipass network zones.
- Five proposed Kubernetes virtual machines.

All VMs share one physical failure domain. Multipass zones simulate
infrastructure separation; they are not independent physical availability
zones.

## 3. Proposed Kubernetes topology

| Node | Role | Proposed zone |
|---|---|---|
| ha-control1 | Control plane / etcd | zone1 |
| ha-control2 | Control plane / etcd | zone2 |
| ha-control3 | Control plane / etcd | zone3 |
| ha-worker1 | Application workloads | zone1 |
| ha-worker2 | Application workloads | zone2 |

Initial VM memory allocation: 1.5 GB each, subject to resource testing.

## 4. Control-plane architecture

The proposed design includes:

- Three control-plane nodes.
- Three stacked etcd members.
- HAProxy for Kubernetes API load balancing.
- Keepalived for API endpoint virtual IP failover.
- A stable Kubernetes controlPlaneEndpoint.

The VIP design is not yet approved. Multipass zones have separate subnets,
so VRRP and VIP failover behaviour must be investigated before selection.

## 5. Workload networking

Cilium is the proposed Kubernetes CNI.

Validation will cover:

- Pod-to-pod connectivity.
- Cross-node connectivity.
- Pod-to-Service connectivity.
- DNS resolution.
- NetworkPolicy enforcement.
- Node and workload failure behaviour.

Kube-proxy replacement is not assumed and requires a separate decision.

## 6. Delivery architecture

1. Engineer proposes a change in GitHub.
2. CI validates source and configuration.
3. Required review and change authorization occur.
4. Flux reconciles approved Kubernetes desired state.
5. Monitoring verifies platform and service health.
6. Deployment evidence is linked to the change record.

GitOps reconciliation does not replace change authorization.

## 7. Observability architecture

The initial design will evaluate:

- Prometheus for metrics collection and alert evaluation.
- Alertmanager for alert grouping and routing.
- Grafana for dashboards.
- Node Exporter for host metrics.
- kube-state-metrics for Kubernetes object state.
- Blackbox Exporter for endpoint availability checks.
- Centralized logging as a separately evaluated capability.

Monitoring will cover the host, nodes, control plane, workloads and critical
service paths.

Monitoring availability and resource consumption will be measured.
The initial monitoring deployment may itself be a single failure domain.

## 8. Security boundaries

Document and validate:

- Host and VM boundaries.
- Kubernetes control-plane access.
- Worker and workload boundaries.
- Administrative access.
- API access.
- GitHub and GitOps trust boundaries.
- Identity and secrets dependencies.
- Monitoring and notification dependencies.

## 9. Known limitations

- All VMs share one physical host.
- Multipass zones are simulated failure domains.
- Local networking does not prove cloud networking behaviour.
- The initial cluster has constrained compute and memory.
- Monitoring may initially be single-instance.
- External notification delivery depends on configured integrations.

## 10. Open architecture questions

1. Can the control-plane nodes support the required API VIP across zones?
2. What routing and firewall rules are required between zone subnets?
3. What resource allocation is sustainable with observability workloads?
4. What logs should be retained, and for how long?
5. Where should backups reside to provide meaningful separation from the
   Kubernetes cluster?
