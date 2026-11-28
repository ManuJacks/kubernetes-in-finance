# Evidence: Kubernetes API audit logging applied, 2026-11-27

Change: [CHG-2026-11-27](../../changes/CHG-2026-11-27-apiserver-audit.md).
Redacted: no tokens, certificates or request bodies.

## 1. Preconditions (00:49 UTC)

- `main` CI green on `708c12b`; 5/5 nodes Ready; `/readyz` 200 on all three
  control planes.
- Newest etcd snapshot `20261128_000054Z` (48 min old).
- `scripts/validate-apiserver-audit-policy.sh`: valid for v1.36.6.
- Node clocks match the host to within 1 s.

## 2. Rollout (00:49:52–00:52:16 UTC)

`15-apiserver-audit.yml`, one node at a time: `tf-ha-control1`,
`tf-ha-control2`, `tf-ha-control3`. `failed=0` on all three; each API server
was recreated once (restart count 0, new container), all with policy
annotation `f0f9dd9bb4998665…`. `tf-ha-control3` took longest: the old
container stopped at 00:51:26, the new one started at 00:52:09. The cluster
kept serving through the load balancer throughout.

## 3. Grant and revoke are recorded

`grant-incident-access.sh --env lab grant app-team-a`, then `revoke`
(00:52:51–00:52:52 UTC), and two reads with a real 10-minute
`prod-debug-sa` token (00:54:14). Extracted with
`scripts/k8s-audit-extract.py`:

| Time (UTC) | Node | User | Verb | Resource | Namespace | Name | Code | Level |
|---|---|---|---|---|---|---|---|---|
| 00:52:51.443 | tf-ha-control1 | `kubernetes-admin` | create | rolebindings | app-team-a | prod-debug-reader | 201 | RequestResponse |
| 00:52:51.512 | tf-ha-control3 | `kubernetes-admin` | patch | rolebindings | app-team-a | prod-debug-reader | 200 | RequestResponse |
| 00:52:51.565 | tf-ha-control2 | `kubernetes-admin` | delete | rolebindings | app-team-a | prod-debug-log-reader | 404 | RequestResponse |
| 00:52:52.182 | tf-ha-control3 | `kubernetes-admin` | delete | rolebindings | app-team-a | prod-debug-reader | 200 | RequestResponse |
| 00:52:52.186 | tf-ha-control3 | `kubernetes-admin` | delete | rolebindings | app-team-a | prod-debug-log-reader | 404 | RequestResponse |
| 00:54:14.650 | tf-ha-control2 | `sa:debug-system:prod-debug-sa` | list | pods | app-team-a | — | 403 | Metadata |
| 00:54:14.701 | tf-ha-control1 | `sa:debug-system:prod-debug-sa` | list | nodes | — | — | 200 | Metadata |

Also recorded: 20 `selfsubjectaccessreviews` (the grant script's
`can-i` checks), impersonating `prod-debug-sa`, at Metadata.

The grant carries `roleRef: prod-debug-reader`. Both `404`s on
`prod-debug-log-reader` are expected: a grant without `--logs` removes any
earlier log grant, and revoke deletes both layers; neither existed. After
revoke, the identity's pod list in `app-team-a` is denied (`403`) and
recorded; its standing node read (Layer 1) is allowed and recorded.

## 4. Nothing sensitive is recorded

Across all three logs: 152 events on Secrets, ConfigMaps, TokenReviews or
token subresources, **0** with a request or response body.

## 5. Finding: impersonation is not covered

The first identity test used `kubectl --as=...prod-debug-sa` and recorded
nothing. The API server evaluates the audit policy before impersonation, so
the request matched as `kubernetes-admin`, whose reads the policy leaves out.
Real tokens are recorded (§3). Accepted: impersonation requires
cluster-admin-level rights, and the impersonator's own writes are still
recorded. Runbook updated.

## 6. Volume

About 37 KB per minute per node right after rollout (mostly the grant
test). At that rate the 250 MiB cap holds roughly 4–5 days, so the cap
rather than the 7-day `maxage` sets retention. Re-measure after a quiet day.
