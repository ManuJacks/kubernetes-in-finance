# Vault validation results

This is an evidence record template. Do not mark a control passed without
capturing the corresponding redacted command output or audit evidence.

| Control | Status | Evidence reference | Notes |
|---|---|---|---|
| Kubernetes TokenReview identity exists | Passed | `vault-token-reviewer` has `system:auth-delegator`; TokenReview check returned `yes` | 2026-11-26 |
| Vault validates KIF Internal CA | Passed | Smoke test completed over verified TLS | 2026-11-26 |
| Pod resolves `vault.kif.io` | Passed | Smoke test reached Vault | 2026-11-26 |
| Pod reaches Vault over TLS | Passed | Smoke test completed login request | 2026-11-26 |
| `debug-system/prod-debug-sa` authenticates | Passed | Kubernetes auth returned `authenticated: true` | 2026-11-26 |
| Token is short-lived | Passed | `lease_duration=900` seconds | 2026-11-26 |
| Application secret path is allowed | Passed | HTTP status `200` | 2026-11-26 |
| Database secret path is denied | Passed | HTTP status `403` | 2026-11-26 |
| Vault audit records auth and access | Pending |  |  |
| Independent snapshot restore succeeds | Pending |  |  |

Never include JWTs, Vault tokens, SecretIDs, or secret values in this record.

## Smoke test

After manual Vault configuration, run:

```bash
scripts/vault-kubernetes-smoke-test.sh
```

The test reports only token TTL/policies and application/database HTTP status
codes. It expects application access to return `200` and database access to
return `403`. Temporary Kubernetes resources are removed automatically.
