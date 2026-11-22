# Runbook: Kubernetes workload and object-state alerts

Alerts in `monitoring/prometheus/rules/kubernetes-workloads.yml`, from
kube-state-metrics (`ansible/playbooks/06c-kube-state-metrics.yml`). They
report what Kubernetes is failing to do; resource consumption is covered by
`resource-limits.yml` (cAdvisor and node metrics).

```bash
export KUBECONFIG=~/.kube/kubernetes-in-finance.conf
```

## KubeStateMetricsDown (ticket)

Every other alert here is silent while this fires.

```bash
kubectl -n kube-system get deploy,pods -l app.kubernetes.io/name=kube-state-metrics
kubectl get --raw /api/v1/namespaces/kube-system/services/kube-state-metrics:http/proxy/metrics | head
```

If the pod is fine but the proxy path fails, check the API VIP and the client
certificate in `~/.local/share/kubernetes-in-finance/monitoring/config/prometheus/`.
Redeploy with `06c-kube-state-metrics.yml`.

## KubeNodeNotReady (page)

```bash
kubectl get nodes
kubectl describe node <node>        # Conditions and recent events
multipass info <node>                # is the VM running?
```

A NotReady control-plane node also shows in the API availability dashboard.
A NotReady worker removes half the workload capacity: pods are evicted after
the default 5-minute toleration. Recovery: `08-replace-worker.yml`.

## KubePodCrashLooping (ticket)

```bash
kubectl -n <ns> logs <pod> -c <container> --previous
kubectl -n <ns> describe pod <pod>   # Last State: exit code and reason
```

Exit code 137 with reason OOMKilled: see below. Exit code 1 or similar: an
application error or bad configuration, visible in the previous logs.

## KubeContainerOOMKilled (page)

Pages because on ~950 MiB workers an OOM kill is the first sign of memory
exhaustion ([ADR-006](../decisions/ADR-006-alerting-policy.md)).

1. Check the node is not next: `kubectl top nodes` and the "Node Memory
   Utilization" panel. If the node is above 85%, treat it as node memory
   pressure first.
2. The container exceeded its own memory limit. Compare usage with the limit
   in the "Top Pods by Memory Working Set" panel.
3. Raise the limit only if the workers have headroom; otherwise fix the
   workload's memory use. Memory limits are already overcommitted (131% on
   `tf-ha-worker1` on 2026-11-22), so a raised limit can move the OOM from the
   container to the node.

## KubeContainerImagePullFailing (ticket)

```bash
kubectl -n <ns> describe pod <pod>   # Events: the exact pull error
```

Common causes: a typo in the image or tag, a private registry without
`imagePullSecrets`, or registry rate limits.

## KubeContainerConfigError (ticket)

Usually a referenced Secret or ConfigMap (or a key in one) does not exist.
`kubectl -n <ns> describe pod <pod>` names it in Events.

## KubePodStuckPending (ticket)

```bash
kubectl -n <ns> describe pod <pod>   # Events: FailedScheduling reason
```

- `Insufficient cpu/memory`: requests exceed free capacity on the workers.
- `untolerated taint`: only workers accept workloads; control planes are tainted.
- `unbound PersistentVolumeClaim`: see KubePersistentVolumeClaimPending.

## KubeDeploymentReplicasUnavailable / KubeStatefulSetReplicasUnavailable (ticket)

Find the failing pods of the workload and follow the alert for their state
(crash loop, Pending, image pull). A pod that is Running but not Ready is
failing its readiness probe: `kubectl -n <ns> describe pod <pod>`.

## KubeDaemonSetPodsUnavailable (ticket)

For `cilium`, a node without an available agent has no pod networking: treat
it as urgent. See [network connectivity](network-connectivity.md).

```bash
kubectl -n <ns> get pods -l <selector> -o wide   # which node is missing a pod
```

## KubeJobFailed (ticket)

```bash
kubectl -n <ns> get pods -l job-name=<job>
kubectl -n <ns> logs -l job-name=<job> --tail=50
```

Delete the Job once understood; the alert clears with it.

## KubePersistentVolumeClaimPending (ticket)

The cluster has no StorageClass yet, so dynamically provisioned claims cannot
bind. Either provision a PersistentVolume by hand or add a provisioner (see
the migration path in [monitoring](../monitoring/README.md)).
