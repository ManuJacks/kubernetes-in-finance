# CHG-2026-11-27: Kubernetes API audit logging

Written with the production-debug Change template
(`docs/procedures/CHANGE_REQUEST_TEMPLATE.md` in
[production-debug](https://github.com/ManuJacks/production-debug)).

| Field | Value |
|---|---|
| Type | Normal |
| Related records | production-debug ADR-SEC-001 §7 item 3 ("No API audit trail yet"); [Vault validation results](../security/VAULT_VALIDATION_RESULTS.md) |
| Configuration items | `kube-apiserver` static pod manifests on `tf-ha-control1..3`; `/etc/kubernetes/audit/policy.yaml`; `/var/log/kubernetes/audit/` |
| Implemented by | Ansible `15-apiserver-audit.yml`, role `apiserver-audit` |
| Risk | Moderate: each API server restarts once. A bad manifest or policy keeps that node's API server down. Mitigated by one node at a time with a stop on first failure, a backup of every manifest, a policy check against the real v1.36.6 binary, and a tested backout |
| Change window | Operator present; not while any other control-plane work is in progress |
| Pull request | #12 (merged `708c12b`) |
| Status | **Implemented 2026-11-27 00:49–00:52 UTC** (approved by the operator in session); [evidence](../security/evidence/2026-11-27-apiserver-audit.md) |

## Justification

Grants, revokes, changes to the admission guard and the diagnostic
identity's reads leave no server-side record. ADR-SEC-001 depends on being
able to show who granted access and what the identity did with it. The
change also makes the Vault-triggered TokenReviews visible from the cluster
side.

## Implementation

1. Precondition checks: all three `/readyz` return 200; an etcd backup less
   than an hour old (`10-etcd-backup.yml` timer status);
   `scripts/validate-apiserver-audit-policy.sh` passes.
2. Run `15-apiserver-audit.yml`. For each node in turn: back up the manifest,
   install the policy, patch the manifest, wait for the new process with
   audit flags, wait for `/readyz`, confirm the log is being written.
3. Verify (runbook, "Verify") and capture redacted evidence in
   `docs/security/evidence/`.

## Test plan and evidence (before applying)

- `scripts/validate-apiserver-audit-policy.sh`: the policy loads in
  `registry.k8s.io/kube-apiserver:v1.36.6`. A deliberately broken copy is
  rejected with exit 1.
- Manifest patch tested against a copy of `tf-ha-control1`'s real manifest:
  `changed`, then `unchanged`, then `absent` restores a manifest equal to
  the original.
- `tests/test_apiserver_audit.py`: Secrets and tokens are never recorded
  with bodies, access changes are recorded in full, the diagnostic identity
  is recorded, the catch-all is last, the patch is idempotent and reversible
  with nothing left in the manifests directory, the playbook uses
  `serial: 1`, and backups sit outside the manifests directory.

## Backout plan

Per node: `-e apiserver_audit_state=absent --limit <node>`, or restore the
manifest from `/var/backups/kube-apiserver/`. Trigger: an API server that is
not ready within 5 minutes of its manifest change.

## Trade-offs accepted

- Up to about 250 MiB of logs per control plane (`tf-ha-control3` has
  8.8 GiB free).
- Routine reads by controllers are not recorded, to keep the volume small.
- `kubeadm upgrade` drops the flags until the playbook is re-run (runbook,
  "Known limit").

## Post-implementation review

| Question | Answer |
|---|---|
| Implemented as planned? | Yes. All preconditions met; three nodes in turn, `failed=0`, one restart each |
| Success check met? | Yes. Grant, revoke and the identity's allowed and denied reads are recorded; 0 sensitive bodies ([evidence](../security/evidence/2026-11-27-apiserver-audit.md)) |
| Unplanned impact? | None. `tf-ha-control3`'s API server was down for 43 s (00:51:26–00:52:09) while the other two served; its mirror pod status lagged a few seconds behind |
| Lesson | The policy is matched before impersonation: `kubectl --as` cannot test identity rules. Use a real short-lived token |
