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

Nothing here grants access to anyone. Incident tooling such as
[production-debug](https://github.com/ManuJacks/production-debug) is given
read access to a tenant namespace only for the length of an incident, and
only if that tool's per-environment allowlist names the namespace. Adding a
namespace here does not make it diagnosable. That is a separate,
reviewed change in the tool's allowlist.
