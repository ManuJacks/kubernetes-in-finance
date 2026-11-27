# ADR-007: Centralized secrets management with external HashiCorp Vault

- **Status:** Accepted. Kubernetes authentication implemented and validated
  2026-11-26; backup/restore, audit evidence and monitoring outstanding
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

This is independence from the *cluster*, not from the *host*. The cluster
nodes are Multipass VMs on the same host, so a host failure takes out both
(the 2026-11-22 Sev 1 was a host-side `multipassd` crash). Host-level
independence needs a second machine and is out of scope for this lab.

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
material is stored independently in KeePassXC.

This is a single-operator lab: one person holds every share. The 3-of-5
threshold therefore protects against losing individual shares, not against
a single insider. With more operators, shares would be split across people
so that no one person can unseal alone. The initial Raft snapshot was
created at `~/vault-backups/kif-vault-initial.snap`, but independent encrypted
backup and restore testing remain outstanding.

### TokenReview credential

Vault calls the Kubernetes TokenReview API with a reviewer JWT stored in its
`auth/kubernetes/config`. Because Vault runs outside the cluster, it has no
local ServiceAccount token to fall back on. Three options:

| Option | Rejected / chosen because |
|---|---|
| Short-lived token (`kubectl create token --duration=10m`) | Rejected: Vault keeps using the stored JWT; once it expires every login fails. The first runbook draft did this |
| No reviewer JWT (Vault reuses each client's JWT) | Rejected: every client ServiceAccount, including `prod-debug-sa`, would need `system:auth-delegator`, widening workload privileges |
| Long-lived token Secret for `kube-system/vault-token-reviewer` | **Chosen** |

Trade-off accepted: a non-expiring credential that can create TokenReviews
and SubjectAccessReviews exists in `kube-system` and in Vault's auth config.
It grants nothing else; it is revoked by deleting the Secret and rotated by
recreating it and rewriting the Vault config
([runbook](../runbooks/vault-kubernetes-auth.md#rotate-the-tokenreview-credential)).

### Policies as code

Vault policies are applied manually, but their source is reviewed in
[`vault/policies/`](../../vault/policies/) and must match the deployed
policies (`vault policy read <name>`). A test fails if the application
policy ever references database paths.

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

Done 2026-11-26 ([evidence](../security/VAULT_VALIDATION_RESULTS.md)):
Kubernetes authentication configured and validated; application/database
cross-boundary denial proven (200 / 403).

1. Switch the Vault config to the long-lived TokenReview credential
   (manual step, [CHG-2026-11-26](../changes/CHG-2026-11-26-vault-kubernetes-auth.md)).
2. Capture Vault audit-log evidence for auth and read events.
3. Integrate the production-debug workload (today only the smoke test uses
   `prod-debug-sa` against Vault).
4. Create an independent encrypted backup and demonstrate restore, with a
   measured restore time
   Done 2026-11-27 for data
   ([drill](../runbooks/vault-restore-drill.md)): encrypted backup on a USB
   disk, restore into an isolated instance 6/6 checks in 96 s (run 1 failed
   on a check defect). Host rebuild remains open (item 8).
5. Add Vault monitoring and alerting under ADR-006.
6. Implement audit log rotation and protection.
7. Set an `audience` on the `prod-debug` role (Vault warns that none is
   configured; it narrows which JWTs the role accepts).
8. Make the Vault host rebuildable: `vault.hcl`, TLS material and the
   systemd unit are outside the snapshot and outside this repository.

## Principles

This decision establishes five platform principles: independence, identity,
least privilege, auditability, and recoverability.
