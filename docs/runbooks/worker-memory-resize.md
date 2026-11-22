# Runbook: resize a worker's memory in place

Risk: **High, platform-wide.** The change goes through multipassd, which
every VM depends on
([PRB-2026-11-22-hypervisor-spof](../problems/PRB-2026-11-22-hypervisor-single-point-of-failure.md)).
One worker per change, the owner watching, a fresh etcd snapshot first.

## How it works

`terraform/main.tf` holds each node's running `memory`;
`terraform_data.node_memory` calls `scripts/multipass-node.sh resize`, which:

1. Does nothing if the size is unchanged.
2. Refuses control-plane nodes; refuses unless `KIF_RESIZE_CONFIRM` names
   **this** node; refuses if multipassd is not active, any other node is
   NotReady **or cordoned**, or the host lacks the extra memory plus 1 GiB.
3. Cordons and drains the node.
4. Powers the guest off from inside (`ssh ... sudo systemctl poweroff`) and
   waits for multipass to report Stopped. It never uses `multipass stop`,
   which crashed multipassd on 2026-11-22.
5. `multipass set local.<node>.memory=<size>`, `multipass start`, waits
   for Ready, uncordons.

## Procedure

Run in your own terminal (Terraform asks for confirmation).

```bash
cd ~/Code/kubernetes-in-finance

# 0. Preconditions
kubectl --kubeconfig ~/.kube/kubernetes-in-finance.conf get nodes   # all Ready, none SchedulingDisabled
systemctl is-active snap.multipass.multipassd                       # active
ANSIBLE_CONFIG=ansible/ansible.cfg ansible 'tf-ha-control*' -i ansible/inventory/hosts.yml \
  -b -f 1 -m shell -a 'systemctl start etcd-backup.service'        # fresh snapshot

# 1. One worker
KIF_RESIZE_CONFIRM=tf-ha-worker2 terraform -chdir=terraform apply \
  -target='terraform_data.node_memory["worker2"]'

# 2. Verify, wait at least 10 minutes, then the other worker
multipass get local.tf-ha-worker2.memory
KIF_RESIZE_CONFIRM=tf-ha-worker1 terraform -chdir=terraform apply \
  -target='terraform_data.node_memory["worker1"]'
```

Expect `KubeNodeNotReady` only if the worker is down longer than about
5 minutes; a normal resize is about 2 minutes.

## If it goes wrong

| Symptom | Action |
|---|---|
| Script refuses in preflight | Nothing changed; fix the reported condition |
| `did not reach Stopped within 120 s` | Node is cordoned and drained, guest may still be running. Check `multipass info <node>`. Do **not** run `multipass stop`; investigate, then `kubectl uncordon` if you abandon the change |
| `multipass list` cannot connect, API `EOF` | multipassd crashed: [multipassd crash runbook](multipassd-crash.md) |
| Node not Ready after start | Left cordoned on purpose; check kubelet (`journalctl -u kubelet`) before uncordoning |
