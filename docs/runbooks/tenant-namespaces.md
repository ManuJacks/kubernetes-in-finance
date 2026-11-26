# Tenant namespaces

Application namespaces are owned by the platform and declared in
`kubernetes/tenants/`. Each one has:

- Pod Security `restricted` enforced (plus `warn` and `audit`).
- A `ResourceQuota` sized for the 950 MiB workers.
- A `kif.io/tenant` label naming the owning team.
- A small non-root sample workload (`web`), so incident tooling has something
  real to diagnose.

| Namespace | Tenant |
|---|---|
| `app-team-a` | team-a |
| `app-team-b` | team-b |

## Apply

```bash
export KUBECONFIG=~/.kube/kubernetes-in-finance.conf
kubectl apply -k kubernetes/tenants
kubectl get pods -l kif.io/tenant -A
```

## Diagnostic access

Nothing here grants access to anyone. Two independent approvals are needed
before [production-debug](https://github.com/ManuJacks/production-debug) can
read a tenant namespace, and only for the length of an incident:

| Approval | Owner | Where | Enforced by |
|---|---|---|---|
| Namespace label `production-debug/diagnosable: "true"` | Platform (this repo) | `kubernetes/tenants/<ns>.yaml` | API server: ValidatingAdmissionPolicy `production-debug-access-guard` |
| Namespace listed in `access/<env>.namespaces` | production-debug maintainers | production-debug repo | `scripts/grant-incident-access.sh` |

A new tenant namespace is **not** diagnosable by default. To approve one, add
the label in a reviewed change here and list the namespace in
production-debug's allowlist. To withdraw approval, remove the label. Existing
bindings are not removed automatically (admission only checks new requests),
so revoke any open grant too:

```bash
kubectl label namespace <ns> production-debug/diagnosable-
<production-debug>/scripts/grant-incident-access.sh revoke <ns>
```
