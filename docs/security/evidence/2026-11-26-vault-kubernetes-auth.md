# Evidence: Vault Kubernetes auth, 2026-11-26

Redacted. No JWTs, Vault tokens or secret values. Captured by the operator
session at about 21:41 EST, roughly one hour after the TokenReview binding
was created (`vault-token-reviewer` ClusterRoleBinding, 2026-11-27T01:43:41Z).

## 1. Smoke test

```console
$ VAULT_INTERNAL_CA_FILE=/usr/local/share/ca-certificates/kif-internal-root-ca.crt \
    scripts/vault-kubernetes-smoke-test.sh
Creating temporary CA ConfigMap and smoke-test pod...
{
  "authenticated": true,
  "lease_duration": 900,
  "policies": [
    "default",
    "production-debug-secrets"
  ]
}
application_path_http_status=200
database_path_http_status=403
Vault Kubernetes smoke test passed; temporary resources will be removed.
```

## 2. Kubernetes RBAC

```console
$ kubectl auth can-i create tokenreviews --as=system:serviceaccount:debug-system:prod-debug-sa
no
$ kubectl get clusterrolebinding -o json   # bindings to system:auth-delegator
metrics-server:system:auth-delegator   2026-11-22T14:49:51Z   [metrics-server]
vault-token-reviewer                   2026-11-27T01:43:41Z   [vault-token-reviewer]
```

The workload ServiceAccount cannot call TokenReview itself, so Vault is not
relying on the client's JWT as the reviewer JWT.

## 3. Vault configuration (read-only, `kif-admin` session)

`vault read auth/kubernetes/config` (CA certificate omitted):

| Field | Value |
|---|---|
| `kubernetes_host` | `https://10.97.3.100:6443` |
| `issuer` | `https://kubernetes.default.svc.cluster.local` |
| `token_reviewer_jwt_set` | `true` |
| `disable_local_ca_jwt` | `false` |

Vault does not return the reviewer JWT, so its expiry cannot be read back.
It is replaced with the long-lived Secret under CHG-2026-11-26.

`vault read auth/kubernetes/role/prod-debug`:

| Field | Value |
|---|---|
| `bound_service_account_names` | `prod-debug-sa` |
| `bound_service_account_namespaces` | `debug-system` |
| `token_policies` | `production-debug-secrets` |
| `token_ttl` / `token_max_ttl` | `900` / `3600` |
| `alias_name_source` | `serviceaccount_uid` |

## 4. Policy drift

```console
$ diff <(vault policy read production-debug-secrets) vault/policies/production-debug-secrets.hcl && echo in sync
production-debug-secrets: in sync
$ diff <(vault policy read production-debug-db-audit) vault/policies/production-debug-db-audit.hcl && echo in sync
production-debug-db-audit: in sync
```

## Not captured

Vault audit-log entries: `/var/log/vault/` is not readable by the operator
account. Captured with sudo on 2026-11-27: see
[2026-11-27 evidence](2026-11-27-vault-tokenreview-credential.md) §4.
