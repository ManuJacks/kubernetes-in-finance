
# Runbook: Kubernetes Network Connectivity Validation

- **Platform:** Kubernetes in Finance
- **Last updated:** 2026-11-05
- **CNI:** Cilium 1.20.4
- **Routing:** VXLAN overlay
- **Purpose:** Diagnose and validate connectivity from the infrastructure
  underlay through Kubernetes workloads.

## 1. Scope

This runbook provides repeatable tests for:

1. Host-to-node connectivity.
2. Cross-zone node connectivity.
3. Node interface and MAC address consistency.
4. Cilium agent health.
5. VXLAN underlay traffic.
6. Cross-node pod connectivity.
7. Kubernetes Service routing.
8. Cluster DNS resolution.
9. Internal source-IP preservation.

A successful test at one layer does not prove that all higher
networking layers are healthy.

## 2. Environment reference

### Infrastructure networks

| Zone | Subnet |
|---|---|
| zone1 | 10.97.0.0/24 |
| zone2 | 10.97.1.0/24 |
| zone3 | 10.97.2.0/24 |

### Kubernetes nodes

| Node | Address | Role |
|---|---|---|
| tf-ha-control1 | 10.97.0.16 | Control plane |
| tf-ha-control2 | 10.97.1.160 | Control plane |
| tf-ha-control3 | 10.97.2.213 | Control plane |
| tf-ha-worker1 | 10.97.0.2 | Worker |
| tf-ha-worker2 | 10.97.1.111 | Worker |

### Kubernetes network ranges

| Network | CIDR |
|---|---|
| Pod network | 10.244.0.0/16 |
| Service network | 10.112.0.0/12 |
| API endpoint | 10.97.3.100:6443 |
| VXLAN transport | UDP 8472 |

### Kubeconfig

The administrative kubeconfig is stored outside the repository:

    ~/.kube/kubernetes-in-finance.conf

Set a shell variable before running cluster commands:

    K=~/.kube/kubernetes-in-finance.conf

## 3. Test 1: Host-to-node connectivity

From the Linux host:

    ping -c 3 10.97.1.111
    ping -c 3 10.97.2.213
    ping -c 3 10.97.0.2

Expected result:

- Three replies per node.
- Zero packet loss.

**Validated:** All three tests passed on 2026-11-05.

Note: ICMP success demonstrates basic reachability only. It does
not prove TCP application connectivity or source-IP preservation.

## 4. Test 2: Node interfaces and MAC addresses

Inspect all Kubernetes nodes:

    ansible all -b -m shell -a '
    echo "=== Hostname ==="
    hostname
    echo
    echo "=== Interfaces and MAC addresses ==="
    ip -br link
    echo
    echo "=== IPv4 addresses ==="
    ip -br -4 address
    '

Expected result:

- Each node has the expected management IP.
- Primary interface MAC addresses are unique.
- No unexpected duplicate node identity is observed.

**Validated:** All five primary node MAC addresses were unique
in the 2026-11-05 inspection.

## 5. Test 3: Kubernetes node readiness

    kubectl --kubeconfig "$K" get nodes -o wide

Expected result:

- All five nodes report Ready.
- Control-plane nodes have the control-plane role.
- Worker nodes are registered and schedulable.

**Validated:** All five nodes Ready on 2026-11-05.

## 6. Test 4: Cilium agent health

    kubectl --kubeconfig "$K" get pods -n kube-system -o wide

Inspect Cilium agents:

    kubectl --kubeconfig "$K" get pods -n kube-system \
      -l k8s-app=cilium -o wide

Expected result:

- One Cilium agent per Kubernetes node.
- All agents Running and Ready.
- No unexplained restart growth.

Inspect Cilium-related components:

    kubectl --kubeconfig "$K" get pods -n kube-system

**Validated:** Cilium agents and Envoy were running on all five
nodes on 2026-11-05.

## 7. Test 5: VXLAN underlay traffic

Cilium uses VXLAN encapsulation for cross-node pod traffic.

Capture UDP 8472 on the Linux host:

    sudo timeout 10 tcpdump -nn -i any 'udp port 8472'

Generate cross-node traffic while the capture is active.

Expected result:

- VXLAN packets are visible.
- Outer source and destination addresses correspond to
  Kubernetes node addresses.
- Packets traverse the expected Multipass zone bridges.

To capture while generating traffic:

    K=~/.kube/kubernetes-in-finance.conf

    sudo -v
    sudo timeout 10 tcpdump -nn -i any 'udp port 8472' \
      > /tmp/cilium-vxlan.txt 2>&1 &
    CAPTURE_PID=$!

    sleep 2

    kubectl --kubeconfig "$K" exec nettest-worker1 -- \
      wget -qO- -T 5 http://10.244.4.167:8080

    wait "$CAPTURE_PID" 2>/dev/null

    grep -E '10\.97\.' /tmp/cilium-vxlan.txt | head -20

**Validated:** VXLAN packets observed on 2026-11-05.
Original node source IPs were visible in the outer packet headers.

## 8. Test 6: Cross-node pod connectivity

Create two temporary HTTP test pods pinned to separate workers:

    kubectl --kubeconfig "$K" run nettest-worker1 \
      --image=busybox:1.36 \
      --restart=Never \
      --overrides='{"spec":{"nodeName":"tf-ha-worker1"}}' \
      --command -- sh -c \
      'mkdir -p /www; echo worker1-ok > /www/index.html; httpd -f -p 8080 -h /www'

    kubectl --kubeconfig "$K" run nettest-worker2 \
      --image=busybox:1.36 \
      --restart=Never \
      --overrides='{"spec":{"nodeName":"tf-ha-worker2"}}' \
      --command -- sh -c \
      'mkdir -p /www; echo worker2-ok > /www/index.html; httpd -f -p 8080 -h /www'

Check pod status and addresses:

    kubectl --kubeconfig "$K" get pods -o wide

Expected test pods:

| Pod | Node | Pod IP |
|---|---|---|
| nettest-worker1 | tf-ha-worker1 | 10.244.3.237 |
| nettest-worker2 | tf-ha-worker2 | 10.244.4.167 |

Test both directions:

    kubectl --kubeconfig "$K" exec nettest-worker1 -- \
      wget -qO- -T 5 http://10.244.4.167:8080

    kubectl --kubeconfig "$K" exec nettest-worker2 -- \
      wget -qO- -T 5 http://10.244.3.237:8080

Expected responses:

    worker2-ok
    worker1-ok

**Validated:** Both directions passed on 2026-11-05.

## 9. Test 7: Service routing

Outstanding validation.

Create a ClusterIP Service selecting a test workload, then test
access through its stable Service IP and DNS name.

Acceptance criteria:

- Service endpoints contain the expected ready pods.
- Requests to the Service reach a backend.
- Traffic continues to work after a backend pod is replaced.

Record the commands, Service IP and results when this test is run.

## 10. Test 8: Cluster DNS

Outstanding validation.

From a workload pod, test:

    nslookup kubernetes.default.svc.cluster.local

Acceptance criteria:

- Cluster DNS resolves the Kubernetes Service name.
- A Service FQDN resolves to the expected Service IP.
- Workload DNS resolution works across nodes.

## 11. Test 9: Internal source-IP preservation

Multipass installs host-level MASQUERADE rules for its zone networks.

Inspect the host NAT rules:

    sudo iptables -t nat -L POSTROUTING -n -v --line-numbers

The internal network exemption should appear before the Multipass
MASQUERADE rules:

    -s 10.97.0.0/16 -d 10.97.0.0/16 -j ACCEPT

Check for the exact rule:

    sudo iptables -t nat -C POSTROUTING \
      -s 10.97.0.0/16 \
      -d 10.97.0.0/16 \
      -j ACCEPT

Capture VXLAN traffic during a cross-zone request.

Expected result:

- The outer VXLAN source address is the originating node IP.
- The source is not rewritten to a Multipass zone gateway.
- The outer destination is the receiving node IP.

Example observed packet:

    10.97.0.2:41875 > 10.97.1.160:8472

This demonstrates preservation of the worker1 source address.

**Validated:** Source-IP preservation observed on 2026-11-05.

The Ansible-managed systemd service and timer maintain the NAT
exemption after boot and periodically reconcile rule ordering.
Host reboot persistence has been validated: the exemption remained
the first POSTROUTING rule and the service executed successfully.

## 12. Troubleshooting guidance

### Node ping fails

Inspect:

- Host routes to zone subnets.
- Multipass bridge state.
- Guest interface addressing.
- Host and guest firewall rules.
- Neighbor resolution.

### Pod-to-pod traffic fails

Inspect:

- Pod readiness and placement.
- Cilium agent health on both nodes.
- Cilium routing and tunnel configuration.
- UDP 8472 reachability.
- Host NAT and forwarding rules.
- Packet captures on the host and affected nodes.

### etcd peer TLS errors

Do not immediately assume certificate corruption.

Check:

1. The peer certificate SANs.
2. The source IP observed in etcd logs.
3. Host POSTROUTING NAT rules.
4. The actual source address in a packet capture.

A translated source address can cause a valid peer certificate
to fail address-based identity validation.

### Service traffic fails

Inspect:

- Service selectors.
- EndpointSlices.
- Pod readiness.
- Cilium Service handling.
- NetworkPolicy enforcement.

## 13. Test cleanup

Remove temporary test pods:

    kubectl --kubeconfig "$K" delete pod \
      nettest-worker1 nettest-worker2

Do not remove test pods until the required evidence has been
captured.

## 14. Validation record

| Test | Result | Date |
|---|---|---|
| Host-to-node connectivity | Pass | 2026-11-05 |
| Node MAC uniqueness | Pass | 2026-11-05 |
| Five-node readiness | Pass | 2026-11-05 |
| Cilium agents on all nodes | Pass | 2026-11-05 |
| VXLAN traffic observed | Pass | 2026-11-05 |
| VXLAN source-IP preservation | Pass | 2026-11-05 |
| Cross-node pod HTTP | Pass, both directions | 2026-11-05 |
| Kubernetes Service routing | Pending | — |
| Cluster DNS | Pending | — |
| NetworkPolicy enforcement | Pending | — |
| Ansible-managed NAT reconciliation | Pass | 2026-11-05 |
| NAT exemption persistence after reboot | Pass | 2026-11-05 |

## 15. Environment limitations

All nodes share one physical host.

Multipass zones simulate network separation but are not independent
physical availability zones.

These tests demonstrate the behavior of this local reference
environment. They do not establish cloud production readiness.
