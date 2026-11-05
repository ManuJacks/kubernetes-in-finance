
# Incident: Cross-zone etcd Peer Connectivity Broken by Source NAT

- **Date:** 2026-11-05
- **Status:** Mitigated; Ansible-managed persistence deployed; reboot validation passed
- **Severity:** Infrastructure bootstrap blocker
- **Affected component:** Kubernetes control-plane etcd peer communication
- **Environment:** Multipass/QEMU, three simulated network zones

## 1. Summary

During expansion of the Kubernetes control plane, etcd peer
communication between control-plane nodes failed.

The receiving etcd member observed peer traffic from a Multipass
zone gateway address rather than the originating control-plane
node address.

This caused TLS peer certificate validation to fail because the
translated source address was not included in the peer certificate
Subject Alternative Names (SANs).

The underlying issue was source NAT applied by Multipass host
networking to traffic crossing zone subnets.

A temporary host-level NAT exemption restored original source IP
preservation for internal platform traffic.

## 2. Architecture context

The Kubernetes nodes occupy three routed Multipass networks:

| Zone | Subnet |
|---|---|
| zone1 | 10.97.0.0/24 |
| zone2 | 10.97.1.0/24 |
| zone3 | 10.97.2.0/24 |

Control-plane nodes:

| Node | Address |
|---|---|
| tf-ha-control1 | 10.97.0.16 |
| tf-ha-control2 | 10.97.1.160 |
| tf-ha-control3 | 10.97.2.213 |

The desktop host routes between the zone bridges.

Multipass had installed MASQUERADE rules for traffic leaving each
zone subnet:

- 10.97.0.0/24
- 10.97.1.0/24
- 10.97.2.0/24

These rules translated cross-zone source addresses.

## 3. Symptoms and evidence

The etcd peer logs showed a connection arriving from
10.97.0.1 rather than the expected control-plane address
10.97.0.16.

The receiving etcd member rejected the connection during TLS
peer certificate validation.

The translated gateway address did not match the peer certificate
identity.

This was a network source-address preservation problem, not evidence
of duplicate node MAC addresses.

## 4. Root cause

Multipass host-level POSTROUTING MASQUERADE rules were translating
traffic between the internal zone networks.

The intended communication path was:

    control-plane node
        -> host zone bridge
        -> routed destination zone
        -> destination control-plane node

Instead, source NAT changed the source address to the originating
zone gateway address.

This broke the relationship between the actual etcd peer identity
and the source address observed by the receiving member.

## 5. Mitigation

A temporary exemption was inserted at the beginning of the host
NAT POSTROUTING chain:

    sudo iptables -t nat -I POSTROUTING 1 \
      -s 10.97.0.0/16 \
      -d 10.97.0.0/16 \
      -j ACCEPT

This prevents subsequent MASQUERADE rules from translating traffic
whose source and destination are both within the internal
10.97.0.0/16 infrastructure range.

The rule is temporary and must be persisted through managed host
configuration.

### 5.1 Persistent host configuration

The temporary NAT exemption has been converted into Ansible-managed
host configuration.

The `host-networking` role installs:

- `/usr/local/sbin/preserve-cluster-source-ips`
- `preserve-cluster-source-ips.service`
- `preserve-cluster-source-ips.timer`

The systemd oneshot service reconciles the exemption into the first
POSTROUTING rule position. The timer runs after boot and repeats
every 30 seconds.

Validation completed:

- Ansible deployment succeeded.
- systemd timer is enabled and active.
- Service executions exit successfully.
- Repeated script execution leaves exactly one exemption.
- The exemption remains the first actual POSTROUTING rule.

Host reboot persistence has been validated. The exemption remained
first in POSTROUTING after reboot, and the reconciliation timer
successfully executed the service.

## 6. Validation evidence

### 6.1 etcd health

All three etcd endpoints subsequently reported healthy and were
able to commit proposals.

Observed endpoints:

- 10.97.0.16:2379
- 10.97.1.160:2379
- 10.97.2.213:2379

### 6.2 Node connectivity

Host-to-node ICMP tests succeeded against:

- 10.97.1.111
- 10.97.2.213
- 10.97.0.2

All three tests returned three replies with zero packet loss.

### 6.3 Pod connectivity

Two BusyBox HTTP test pods were deployed:

| Pod | Node | Pod IP |
|---|---|---|
| nettest-worker1 | tf-ha-worker1 | 10.244.3.237 |
| nettest-worker2 | tf-ha-worker2 | 10.244.4.167 |

HTTP connectivity succeeded in both directions:

- worker1 to worker2 returned `worker2-ok`
- worker2 to worker1 returned `worker1-ok`

### 6.4 VXLAN source-address preservation

A host packet capture observed VXLAN traffic on UDP port 8472.

Example outer packet addresses:

    10.97.0.2:41875 > 10.97.1.160:8472
    10.97.1.160:59669 > 10.97.0.2:8472

The packets traversed the expected zone bridges.

The original node source address 10.97.0.2 was preserved rather
than translated to 10.97.0.1.

The capture included 184 packets.

Note: these particular packet examples were between worker1 and
control2. The separate HTTP tests demonstrated worker1-to-worker2
pod connectivity.

### 6.5 MAC address inspection

The five Kubernetes nodes had unique primary interface MAC addresses.
The host neighbor table mapped the node IP addresses to their
corresponding primary interface MAC addresses.

No duplicate node MAC address was identified in the inspected data.

## 7. Current outcome

The NAT exemption restored the required source-address preservation.

The cluster subsequently reached the following state:

- Three control-plane nodes Ready.
- Two worker nodes Ready.
- All five Cilium agents running.
- Cross-node pod HTTP connectivity successful.
- VXLAN traffic visible on UDP 8472.
- All three etcd endpoints healthy.

An Ansible-managed systemd service and timer now maintain the
NAT exemption on the host. Deployment, successful service execution,
rule ordering, and idempotency have been validated.

Host reboot validation passed. After reboot, the NAT exemption
remained the first POSTROUTING rule and the systemd timer
successfully executed the reconciliation service. All five
Kubernetes nodes recovered to Ready, API readiness checks passed,
and all three etcd endpoints successfully committed proposals.

## 8. Corrective and preventive actions

- [x] Persist the internal NAT exemption through Ansible-managed
      host configuration.
- [x] Reconcile rule ordering periodically after Multipass startup.
- [x] Make rule application idempotent.
- [x] Validate source-IP preservation after host reboot.
- [x] Add node and pod connectivity tests to the networking runbook.
- [x] Retain packet-capture evidence for future regression testing.
- [x] Document the dependency on host-level routing and NAT behavior.

## 9. Lessons learned

- Successful ICMP connectivity does not prove source-address
  preservation.
- TLS certificate errors can originate from network translation
  rather than incorrect certificates.
- Packet captures provide evidence of the actual underlay path.
- Simulated network zones require explicit inspection of host
  forwarding and NAT behavior.
- A temporary operational fix must be converted into managed,
  persistent configuration.
- Validation should test both application connectivity and
  underlying network identity preservation.

## 10. Environment limitations

All virtual machines and simulated zones share one physical host.

The results demonstrate behavior in this Multipass/QEMU lab.
They do not establish independent physical availability zones
or guarantee identical behavior in a cloud environment.
