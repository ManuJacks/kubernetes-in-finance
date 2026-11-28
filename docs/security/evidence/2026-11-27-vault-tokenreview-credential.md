# Evidence: long-lived TokenReview credential, 2026-11-27

Redacted. No JWTs, Vault tokens or secret values. Captured during
CHG-2026-11-26, part 2, step 3, on 2026-11-27 at about 19:15 EST
(2026-11-28T00:15Z).

## 0. Starting state

Vault was found sealed (`Unseal Progress 0/3`) at the start of the change.
The operator unsealed it with 3 of the 5 Shamir shares and logged in with
`vault login -no-print -method=userpass username=robert` (policies
`default`, `kif-admin`). No key share or token passed through the change
tooling.

## 1. Kubernetes side

```console
$ ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/14-vault-kubernetes-prereqs.yml
PLAY RECAP: localhost ok=10 changed=2 unreachable=0 failed=0
$ kubectl -n kube-system get secret vault-token-reviewer-token \
    -o jsonpath='{.type} created {.metadata.creationTimestamp}'
kubernetes.io/service-account-token created 2026-11-28T00:08:41Z
```

The Secret did not exist before, so the rotation runbook's step 1 (delete the
old Secret) did not apply.

## 2. Vault config rewrite

`vault write auth/kubernetes/config` at 2026-11-28T00:15:02Z, with
`token_reviewer_jwt` read from the Secret above (never printed), and
`kubernetes_host`, `kubernetes_ca_cert` and `issuer` supplied unchanged.

Read back (CA certificate omitted, 1107 bytes, same length as the saved
`vault-kubernetes-ca.crt`):

| Field | Value |
|---|---|
| `kubernetes_host` | `https://10.97.3.100:6443` |
| `issuer` | `https://kubernetes.default.svc.cluster.local` |
| `token_reviewer_jwt_set` | `true` |
| `disable_local_ca_jwt` | `false` |

## 3. Smoke test, immediately after

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

## 4. Pending: 24-hour re-run

Vault cannot return the reviewer JWT, so whether it expires can only be shown
by a login that still works later. Re-run the smoke test no earlier than
2026-11-29T00:15Z (2026-11-28 19:15 EST) and add the output here as §5.
