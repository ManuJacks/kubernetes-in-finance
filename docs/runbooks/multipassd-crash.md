# Runbook: multipassd crashed, VMs disconnected

All VMs run under one daemon, `multipassd`, on the desktop host. If it
crashes, the VMs keep running but its failed restarts tear down the zone
bridges and NAT rules: every cross-zone path, including the API VIP, goes
down. First seen in
[INC-2026-11-22-api-outage-multipassd](../incidents/INC-2026-11-22-api-outage-multipassd.md).

## Recognise it

- `ApiAvailabilityFastBurn` pages; `kubectl` returns `EOF`.
- `multipass list`: `cannot connect to the multipass socket`.
- `systemctl status snap.multipass.multipassd`: `failed`, with one of
  - `dnsmasq died ... Ensure nothing is using port 53` (an orphaned dnsmasq
    from the crashed daemon holds port 53 on the zone bridges), or
  - `Failed to get shared "write" lock` on an instance image (orphaned QEMU
    processes hold the disks).
- `ip -br addr | grep mpqemubr`: bridges `DOWN` or missing; SSH to VMs fails.

## Recover (about 5 minutes)

```bash
sudo scripts/recover-multipassd.sh     # lists what it will stop; type 'recover'
multipass list                         # as your user: all tf-ha-* and api-lb* Running
```

The script refuses to act while multipassd is healthy, stops orphaned
dnsmasq and QEMU (workers, control planes, then load balancers), and starts
the daemon, which rebuilds the bridges and restarts the VMs that were
running. To the guests this is a power cut. It is safe for etcd when the
zones have been disconnected since the crash: no quorum, so no writes.

## Verify

```bash
curl -sk https://10.97.3.100:6443/readyz          # 200 through the VIP
kubectl get nodes                                  # all Ready; uncordon if a change left any cordoned
ansible all -i ansible/inventory/hosts.yml -b -m shell -a 'chronyc tracking | grep "System time"'
# etcd: all three members on the same raft term and applied index
ansible tf-ha-control1 -i ansible/inventory/hosts.yml -b -m shell -a \
  'etcdctl --endpoints=https://10.97.0.16:2379,https://10.97.1.160:2379,https://10.97.2.213:2379 \
   --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key endpoint status -w table'
```

Expect `EtcdBackupFailed` tickets for the outage window (the NFS store was
unreachable); they clear after the next hourly backup succeeds.

## Do not

- Start a VM with `multipass start` while its old QEMU process still runs:
  two QEMU processes on one disk image can corrupt it.
- Kill only some QEMU processes and restart the daemon: it cannot adopt
  running VMs.
