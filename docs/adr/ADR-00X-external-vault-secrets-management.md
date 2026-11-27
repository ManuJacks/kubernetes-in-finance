# ADR-00X: Centralized secrets management with external HashiCorp Vault

- **Status:** Accepted direction; implementation and validation in progress
- **Scope:** Kubernetes-in-Finance (KIF) and the production-debug platform
- **Date:** 2026-11-26

## Context

KIF needs centralized infrastructure and application secret management without
creating a circular recovery dependency. Kubernetes must not be responsible
for protecting the secrets required to recover or administer Kubernetes.
Applications must not depend on human administrator credentials, and workload
access must be least-privilege, auditable, revocable, and time-limited.

## Decisions

### External security control plane

Vault runs directly on the Linux Mint host as a systemd-managed service. It is
not deployed as a Kubernetes pod, Helm release, or operator. Vault therefore
remains available when the Kubernetes cluster is unavailable.

### Storage and availability

Vault uses integrated Raft storage at `/opt/vault/data`, with node ID
`kif-vault-01`. The current deployment is a single-node Vault service at
`https://vault.kif.io:8200`. Raft is the storage architecture; it is not proof
of high availability. Multi-node Vault is explicitly deferred until tested
recovery, monitoring, independent backups, and service-availability needs
justify the added operational complexity.

### Trust and TLS

Vault uses the KIF Internal CA, with hostname `vault.kif.io` and listener
`10.97.3.1:8200`. TLS verification must remain enabled. Certificate problems
must be corrected through PKI or trust-store changes, never by disabling
verification.

### Human and workload identities

Human administration uses the `kif-admin` policy. Workloads must never receive
the Vault root token or human administrator policy.

Kubernetes workloads use Kubernetes authentication. External automation or
non-Kubernetes workloads may use AppRole. Existing AppRole identities remain
separate and are not a substitute for in-cluster workload identity.

### Least privilege

Application and database diagnostic policies remain separate:

- `production-debug-secrets` reads application paths only.
- `production-debug-db-audit` reads database diagnostic paths only.

The target in-cluster identity is `debug-system/prod-debug-sa`, bound to the
application policy only. Negative testing must prove that application access
to database paths is denied.

### Audit and recovery

The existing Vault file audit device at `/var/log/vault/audit.log` is retained.
Audit data is sensitive and requires restricted access, rotation, disk
protection, and backup.

Vault uses Shamir recovery with five shares and a threshold of three. Recovery
material is stored independently in KeePassXC. The initial Raft snapshot was
created at `~/vault-backups/kif-vault-initial.snap`, but independent encrypted
backup and restore testing remain outstanding.

## Kubernetes authentication flow

1. Kubernetes issues a ServiceAccount JWT.
2. The workload presents it to Vault.
3. Vault validates it through Kubernetes TokenReview.
4. Vault verifies the namespace and ServiceAccount.
5. Vault issues a short-lived policy-bound token.
6. The workload reads only its authorized KV v2 paths.

The Kubernetes-side prerequisite is managed by
[the Vault Kubernetes auth runbook](../runbooks/vault-kubernetes-auth.md).
Vault-side configuration remains a manual, human-authorized operation.

## Consequences

Positive consequences include control-plane independence, separation of human
and machine identity, short-lived credentials, least-privilege access,
auditable operations, and recoverability without circular dependencies.

Trade-offs include operating an additional security service, a current
single-node failure domain, PKI and network maintenance, TokenReview trust,
independent backup procedures, and separate Vault monitoring.

## Outstanding work

1. Configure and validate Kubernetes authentication.
2. Integrate the production-debug workload.
3. Prove application/database cross-boundary denial.
4. Create independent encrypted backup and demonstrate restore.
5. Add Vault monitoring and alerting.
6. Implement audit log rotation and protection.

## Principles

This decision establishes five platform principles: independence, identity,
least privilege, auditability, and recoverability.
