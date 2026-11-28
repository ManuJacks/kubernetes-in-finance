# Vault validation results

Do not mark a control passed without linking captured, redacted command
output or audit evidence.

The first version of this record (commit 8da11b1) marked controls passed
with descriptions only. They were re-run and captured on 2026-11-26 about
21:41 EST; the links below point to that capture.

E = [2026-11-26 evidence](evidence/2026-11-26-vault-kubernetes-auth.md)

| Control | Status | Evidence | Date |
|---|---|---|---|
| Kubernetes TokenReview identity exists | Passed | E §2 | 2026-11-26 |
| Workload SA cannot call TokenReview itself | Passed | E §2 | 2026-11-26 |
| Pod resolves `vault.kif.io` and validates KIF Internal CA | Passed | E §1 (login over verified TLS) | 2026-11-26 |
| `debug-system/prod-debug-sa` authenticates | Passed | E §1 `authenticated: true` | 2026-11-26 |
| Token is short-lived | Passed | E §1 `lease_duration: 900`; E §3 role TTLs | 2026-11-26 |
| Application secret path is allowed | Passed | E §1 HTTP `200` | 2026-11-26 |
| Database secret path is denied | Passed | E §1 HTTP `403` | 2026-11-26 |
| Deployed policies match `vault/policies/` | Passed | E §4 | 2026-11-26 |
| Vault uses the long-lived TokenReview credential | Passed | [2026-11-27 evidence](evidence/2026-11-27-vault-tokenreview-credential.md) §1–3 | 2026-11-27 |
| Logins still work more than 24 h after configuration | Pending | Re-run smoke test no earlier than 2026-11-29T00:15Z ([evidence](evidence/2026-11-27-vault-tokenreview-credential.md) §4) | |
| Vault audit records auth and access | Pending | Audit log not readable by operator account | |
| Encrypted backup on removable media | Passed | `kif-vault-20261127T054931Z.snap.gpg`, SHA-256 verified, gpg AES256 | 2026-11-27 |
| Independent snapshot restore succeeds | Passed (run 2; run 1 failed on a drill defect) | [restore drill results](../runbooks/vault-restore-drill.md#results): 6/6 checks, 96 s incl. human steps | 2026-11-27 |

Never include JWTs, Vault tokens, SecretIDs, or secret values in this record.

## Smoke test

After manual Vault configuration, run:

```bash
scripts/vault-kubernetes-smoke-test.sh
```

The test reports only token TTL/policies and application/database HTTP status
codes. It expects application access to return `200` and database access to
return `403`. Temporary Kubernetes resources are removed automatically.
