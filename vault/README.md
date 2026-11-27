# Vault configuration source

Vault runs on the host, outside Kubernetes (ADR-007). Nothing in this
directory is applied automatically: an authorized operator applies it by
hand, under a change record.

| File | Applied with |
|---|---|
| `policies/production-debug-secrets.hcl` | `vault policy write production-debug-secrets vault/policies/production-debug-secrets.hcl` |
| `policies/production-debug-db-audit.hcl` | `vault policy write production-debug-db-audit vault/policies/production-debug-db-audit.hcl` |

The files must match what is deployed. Check for drift with:

```bash
for p in production-debug-secrets production-debug-db-audit; do
  diff <(vault policy read "$p") "vault/policies/$p.hcl" && echo "$p: in sync"
done
```

Human-administration policies (`kif-admin`, `kif-secrets-admin`) are not
recorded here yet.
