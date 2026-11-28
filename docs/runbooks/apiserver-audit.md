# Runbook: Kubernetes API audit logging

Change record: [CHG-2026-11-27](../changes/CHG-2026-11-27-apiserver-audit.md).
Closes the "no API audit trail" gap in production-debug ADR-SEC-001 §7, item 3.

## What it records

Policy: `ansible/roles/apiserver-audit/files/audit-policy.yaml` (first match wins).

| Requests | Level |
|---|---|
| Health, discovery, events, leases | None |
| Secrets, ConfigMaps, ServiceAccount tokens, TokenReviews, SubjectAccessReviews | Metadata only (never bodies) |
| RBAC writes; ValidatingAdmissionPolicy and binding writes | RequestResponse |
| Namespace writes (the `production-debug/diagnosable` label) | Request |
| Anything by `debug-system/prod-debug-sa`, reads included | Metadata |
| Any other write | Metadata |
| Everything else | None |

Logs go to `/var/log/kubernetes/audit/audit.log` on each control plane
(root only, 0700), rotated by the API server: 50 MiB per file, 4 old files,
7 days. Worst case is about 250 MiB per node; at the first measured rate
(about 37 KB per minute) the size cap, not the 7 days, sets retention.

## Apply

Preconditions: all three API servers ready, an etcd backup less than an hour
old, and the policy validated with the real binary:

```bash
scripts/validate-apiserver-audit-policy.sh      # expects "audit policy valid"
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook \
  -i ansible/inventory/hosts.yml ansible/playbooks/15-apiserver-audit.yml
```

The playbook changes one control plane at a time. For each node it backs up
the manifest to `/var/backups/kube-apiserver/`, adds the flags and volumes,
waits until the running process has `--audit-policy-file`, waits for
`/readyz`, and checks that the log is being written. It stops at the first
failure, so at most one API server is affected. The other two keep serving
through the load balancer.

A policy change alone also restarts the API servers: the role stores the
policy's SHA-256 as a pod annotation, so the kubelet sees a new manifest.

## Verify

Run a grant and revoke, then read with a real token for the identity (not
`kubectl --as`: the policy is matched before impersonation, so impersonated
reads are not recorded):

```bash
scripts/grant-incident-access.sh --env lab grant app-team-a
scripts/grant-incident-access.sh --env lab revoke app-team-a
TOK=$(kubectl -n debug-system create token prod-debug-sa --duration=10m)
KUBECONFIG=/dev/null kubectl --server=https://10.97.3.100:6443 \
  --certificate-authority=$HOME/.local/share/kubernetes-in-finance/vault-kubernetes-ca.crt \
  --token="$TOK" -n app-team-a get pods      # expect Forbidden
unset TOK
```

Then, on each control plane (each request lands on one of them):

```bash
sudo python3 -I k8s-audit-extract.py <start time, UTC>
```

`scripts/k8s-audit-extract.py` prints only who, what, where and the result:
no bodies. First run: [2026-11-27 evidence](../security/evidence/2026-11-27-apiserver-audit.md).

## If an API server does not come back

1. The other two keep serving. Check with
   `kubectl get --raw /readyz` through the load balancer.
2. On the failed node, read the error:
   `sudo crictl ps -a --name kube-apiserver` and
   `sudo crictl logs <id> 2>&1 | tail`.
3. Back out on that node only:

   ```bash
   ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook \
     -i ansible/inventory/hosts.yml ansible/playbooks/15-apiserver-audit.yml \
     -e apiserver_audit_state=absent --limit <node>
   ```

   If Ansible cannot run, copy the newest file from
   `/var/backups/kube-apiserver/` over
   `/etc/kubernetes/manifests/kube-apiserver.yaml` by hand. Never put a
   backup inside `/etc/kubernetes/manifests`: the kubelet runs every file there.
4. If the container runs but the kubelet keeps failing with
   `name ... is reserved`, use `12-recover-static-pod.yml`.

## Known limit: kubeadm does not know about this

The flags are in the static pod manifests only, not in the `kubeadm-config`
ConfigMap or `kubeadm-init.yaml.j2`. `kubeadm upgrade` regenerates the
manifest and drops them. After any kubeadm upgrade or control-plane rejoin,
run the playbook again. The follow-up is to move this into
`ClusterConfiguration.apiServer.extraArgs` and `extraVolumes`.
