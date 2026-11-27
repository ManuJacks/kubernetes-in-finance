# CHG-2026-11-26: Vault Kubernetes authentication for production-debug

Written with the production-debug Change template
(`docs/procedures/CHANGE_REQUEST_TEMPLATE.md` in
[production-debug](https://github.com/ManuJacks/production-debug)).

**Retroactive record.** Part 1 was implemented and pushed straight to `main`
(commit 8da11b1) without a pull request, CI run or change record, although
the runbook's preconditions require "an approved change record". This record
and its pull request close that gap; part 2 is the correction that the review
of part 1 raised.

| Field | Value |
|---|---|
| Type | Normal |
| Related records | [ADR-007](../decisions/ADR-007-external-vault-secrets-management.md) |
| Configuration items | Kubernetes: `kube-system/vault-token-reviewer` (SA, ClusterRoleBinding, token Secret). Vault: `auth/kubernetes` mount, config, role `prod-debug`; policies `production-debug-secrets`, `production-debug-db-audit` |
| Implemented by | Ansible `14-vault-kubernetes-prereqs.yml` (Kubernetes side); operator by hand (Vault side) |
| Risk | Moderate: a new trust path from the cluster into the secrets control plane. Mitigated by a role bound to one ServiceAccount, one read-only policy, 15-minute tokens, and a tested database denial |
| Pull request | Part 1: none (8da11b1 on `main`). Part 2: branch `fix/vault-k8s-auth-corrections` |

## Justification

production-debug needs application secrets without human credentials or
Kubernetes Secrets, from a control plane that survives cluster failure
(ADR-007).

## Implementation

**Part 1 (done 2026-11-26, 8da11b1).** Ansible created the TokenReview
ServiceAccount and binding; the operator enabled Kubernetes auth in Vault,
wrote its config and the `prod-debug` role.

**Part 2 (this pull request).**

1. Ansible also creates a long-lived token Secret,
   `kube-system/vault-token-reviewer-token`. The runbook's 10-minute
   `kubectl create token` JWT would stop every login once it expired.
2. Vault policies are recorded in `vault/policies/`, verified identical to
   the deployed ones.
3. Evidence is captured; the ADR is numbered, located and updated.

**Part 2, step 3 (manual, operator, pending).** Run the playbook, then
rewrite `auth/kubernetes/config` with the Secret's JWT (runbook, "Rotate the
TokenReview credential", steps 2–4).

## Test plan and evidence

- **Before part 2:** smoke test passed about 1 hour after setup: login,
  `lease_duration` 900, application `200`, database `403`
  ([evidence](../security/evidence/2026-11-26-vault-kubernetes-auth.md)).
  The reviewer JWT's expiry cannot be read back from Vault.
- **After step 3:** smoke test passes immediately, and again more than 24 h
  later (proves the reviewer credential no longer expires).
- **Static guards:** `tests/test_vault_kubernetes_auth.py` fails if the
  application policy references database paths, if the role stops creating
  the long-lived Secret, or if the runbook goes back to `kubectl create token`.

## Trade-off accepted

A non-expiring TokenReview credential exists in `kube-system` and in Vault.
It can only create TokenReviews and SubjectAccessReviews; it is rotated
yearly or on exposure (ADR-007).

## Backout plan

Part 2: rewrite the Vault config with a fresh reviewer JWT and delete the
Secret. Whole change: `vault auth disable kubernetes`, then the runbook's
Recovery section. Trigger: any login failure that the smoke test reproduces
and that cannot be fixed within the change window.

## Post-implementation review

| Question | Answer |
|---|---|
| Implemented as planned? | Part 1 yes, but outside the change process (see above). Part 2 pending step 3 |
| Success check met? | Part 1 yes (evidence). Part 2 pending the 24-hour re-run |
| Unplanned impact? | None observed |
| Lesson | Security-control-plane changes go through a PR like every other change; "manual Vault step" does not exempt the Kubernetes and docs side |
