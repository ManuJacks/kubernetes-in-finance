# Vault Kubernetes authentication runbook

This runbook prepares the KIF Kubernetes cluster for Vault Kubernetes
authentication. Vault runs outside Kubernetes and its configuration remains a
manual, human-authorized operation.

## Scope and safety

The Ansible playbook changes only Kubernetes:

- creates `kube-system/vault-token-reviewer`;
- grants it the `system:auth-delegator` ClusterRole;
- creates its long-lived token Secret `kube-system/vault-token-reviewer-token`;
- saves the Kubernetes CA for the Vault operator;
- does not contact Vault;
- does not create Vault auth mounts, policies, roles, tokens, or secrets.

The target workload identity is `debug-system/prod-debug-sa`. Its existing
Kubernetes RBAC remains separate from Vault access, and it must not receive
database diagnostic policy access.

Vault is a single-node Raft deployment. This integration must not be described
as highly available Vault.

## Preconditions

Confirm the operator has:

- a current KIF kubeconfig at `~/.kube/kubernetes-in-finance.conf`;
- authorized access to the KIF cluster;
- the KIF Internal Root CA for verifying `vault.kif.io`;
- a Vault administrator session for the manual Vault steps;
- an approved change record.

Inspect the existing identity before applying changes:

```bash
export KUBECONFIG="$HOME/.kube/kubernetes-in-finance.conf"
kubectl -n debug-system get serviceaccount prod-debug-sa -o yaml
kubectl auth can-i --list \
  --as=system:serviceaccount:debug-system:prod-debug-sa
```

## Prepare Kubernetes with Ansible

Run from the repository root:

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg \
ansible-playbook \
  -i ansible/inventory/hosts.yml \
  ansible/playbooks/14-vault-kubernetes-prereqs.yml
```

The playbook saves the Kubernetes CA at:

```text
~/.local/share/kubernetes-in-finance/vault-kubernetes-ca.crt
```

Verify the Kubernetes-side result:

```bash
kubectl -n kube-system get serviceaccount vault-token-reviewer
kubectl get clusterrolebinding vault-token-reviewer -o yaml
kubectl auth can-i create tokenreviews \
  --as=system:serviceaccount:kube-system:vault-token-reviewer
```

The last command should return `yes`.

## Manual Vault configuration

These commands are intentionally not part of Ansible. Run them in the
operator's secured Vault administration environment, with the KIF Internal
Root CA configured for Vault CLI TLS verification.

Set the values from the cluster inventory and playbook output:

```bash
export VAULT_ADDR=https://vault.kif.io:8200
export VAULT_CACERT=/path/to/kif-internal-root-ca.crt
export KUBERNETES_HOST=https://10.97.3.100:6443
export KUBERNETES_ISSUER=https://kubernetes.default.svc.cluster.local
export KUBERNETES_CA_CERT="$HOME/.local/share/kubernetes-in-finance/vault-kubernetes-ca.crt"
```

Read the long-lived TokenReview JWT from the Secret the playbook created; do
not commit it, print it or paste it into chat:

```bash
export TOKEN_REVIEWER_JWT="$(kubectl -n kube-system get secret vault-token-reviewer-token \
  -o jsonpath='{.data.token}' | base64 -d)"
```

Do not use `kubectl create token` here. Vault keeps the reviewer JWT and
uses it for every login; a short-lived token makes every login fail once it
expires (ADR-007, "TokenReview credential").

Then, as an authorized Vault administrator:

```bash
vault auth enable kubernetes
vault write auth/kubernetes/config \
  token_reviewer_jwt="$TOKEN_REVIEWER_JWT" \
  kubernetes_host="$KUBERNETES_HOST" \
  kubernetes_ca_cert=@"$KUBERNETES_CA_CERT" \
  issuer="$KUBERNETES_ISSUER"

vault write auth/kubernetes/role/prod-debug \
  bound_service_account_names=prod-debug-sa \
  bound_service_account_namespaces=debug-system \
  policies=production-debug-secrets \
  ttl=15m \
  max_ttl=1h
```

If the auth mount or role already exists, inspect it first and update only the
approved fields. Do not modify the existing AppRole identities unless the
external-automation use case requires it.

## Workload validation

From a temporary pod using `debug-system/prod-debug-sa`, verify:

1. DNS resolves `vault.kif.io`.
2. TLS validates with the KIF Internal Root CA.
3. Kubernetes authentication succeeds.
4. The returned token is short-lived.
5. The application path under `secret/data/production-debug/application/` is readable.
6. The database path under `secret/data/production-debug/database/` is denied.

Never print JWTs, Vault tokens, SecretIDs, or secret values. Record only
redacted command results, token TTL metadata, policy names, HTTP status codes,
and Vault audit event metadata.

## Evidence checklist

- [ ] Ansible output shows Kubernetes resources applied.
- [ ] `vault-token-reviewer` is bound to `system:auth-delegator`.
- [ ] Vault Kubernetes auth configuration was reviewed by a human.
- [ ] Vault uses the long-lived `vault-token-reviewer-token`, not a `kubectl create token` JWT.
- [ ] Vault role is bound exactly to `debug-system/prod-debug-sa`.
- [ ] Application policy is `production-debug-secrets` only.
- [ ] Database access is denied.
- [ ] Vault audit log contains authentication and read events without secret values.
- [ ] Kubernetes API, pod-to-Vault routing, DNS, and TLS checks pass.

## Rotate the TokenReview credential

Rotate on suspected exposure, when an operator with access leaves, and at
least yearly. Logins fail from step 1 until step 3 completes (about a
minute), so do it in a change window:

```bash
# 1. Revoke the old token by deleting its Secret.
kubectl -n kube-system delete secret vault-token-reviewer-token
# 2. Recreate it.
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook \
  -i ansible/inventory/hosts.yml ansible/playbooks/14-vault-kubernetes-prereqs.yml
# 3. Rewrite the Vault config. The write does not merge with the existing
#    config, so supply every field (variables from "Manual Vault configuration").
TOKEN_REVIEWER_JWT="$(kubectl -n kube-system get secret vault-token-reviewer-token \
  -o jsonpath='{.data.token}' | base64 -d)"
vault write auth/kubernetes/config \
  token_reviewer_jwt="$TOKEN_REVIEWER_JWT" \
  kubernetes_host="$KUBERNETES_HOST" \
  kubernetes_ca_cert=@"$KUBERNETES_CA_CERT" \
  issuer="$KUBERNETES_ISSUER"
unset TOKEN_REVIEWER_JWT
vault read auth/kubernetes/config   # check: token_reviewer_jwt_set=true, host and issuer unchanged
# 4. Prove it.
scripts/vault-kubernetes-smoke-test.sh
```

## Recovery

To remove the Kubernetes TokenReview prerequisite after disabling Vault
Kubernetes authentication and confirming no other Vault consumer uses it:

```bash
kubectl -n kube-system delete secret vault-token-reviewer-token
kubectl delete clusterrolebinding vault-token-reviewer
kubectl -n kube-system delete serviceaccount vault-token-reviewer
```

Revoke any Vault tokens issued to the workload according to the Vault change
record. Preserve the audit log and validation evidence.
