# ADR-001: Use Multipass for Local Infrastructure

- **Status:** Proposed
- **Date:** 2026-11-02

## Context

The project requires repeatable virtual infrastructure to demonstrate
Kubernetes architecture, failure scenarios and operational procedures.

The available development environment is a Linux Mint desktop with
16 GB RAM, an AMD Ryzen 5 3600X and Multipass 1.17 using QEMU.

## Decision

Use Multipass to provision Ubuntu virtual machines on the local host.

Use three Multipass zones to simulate infrastructure failure domains,
subject to validation of their networking behaviour.

## Alternatives considered

- **Cloud infrastructure:** More realistic independent failure domains,
  but introduces cost and external dependencies.
- **Nested virtualization using another hypervisor:** More configuration
  and operational overhead without a clear initial benefit.
- **Containers instead of VMs:** Insufficient isolation for demonstrating
  node-level and operating-system failure scenarios.

## Consequences

Positive:
- Local and repeatable infrastructure.
- No cloud consumption charges.
- Ability to simulate node failures and rebuild environments.
- Suitable for public, reproducible lab instructions.

Limitations:
- All VMs share one physical host.
- Multipass zones are not independent physical availability zones.
- Host resource constraints affect all virtual machines.
- Local networking may differ from cloud networking.

## Validation

- Verify zone assignment for each VM.
- Verify inter-zone connectivity.
- Test VM stop/start and failure scenarios.
- Measure host memory and CPU consumption.
- Document the limitations of simulated availability zones.
