# Vault Kubernetes authentication

This document describes the implementation boundary for in-cluster Vault
authentication. The step-by-step procedure is in the
[Vault Kubernetes authentication runbook](../runbooks/vault-kubernetes-auth.md).

## Responsibility boundary

Ansible manages only Kubernetes prerequisites:

- `kube-system/vault-token-reviewer`;
- its `system:auth-delegator` binding;
- retrieval of the Kubernetes CA used for TokenReview verification.

Vault auth mounts, Vault roles, policies, and Vault tokens are configured
manually by an authorized operator. This prevents an infrastructure playbook
from silently changing the secrets control plane.

## Target identity

```text
Namespace:       debug-system
ServiceAccount:  prod-debug-sa
Vault policy:    production-debug-secrets
Token TTL:       15 minutes
Maximum TTL:     1 hour
```

The database diagnostic policy is intentionally excluded.

## Required evidence

Record redacted results for Kubernetes identity/RBAC, API reachability, DNS,
Vault TLS validation, TokenReview success, application-path authorization, and
database-path denial. Never record JWTs, Vault tokens, SecretIDs, or secret
values.
