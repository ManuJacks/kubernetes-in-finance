#!/usr/bin/env bash
# Workload recovery drill (KPI 5: workload recovery <= 6 min).
#
# Powers off one worker (multipass stop --force: no graceful shutdown) and
# times how long Kubernetes takes, with default settings, to restore full
# capacity of a two-replica Deployment (kubernetes/drills/workload-recovery.yaml).
# Results are exported as Prometheus textfile metrics, like the restore drill.
#
# Disruptive by design: every pod on the worker is evicted, and the
# KubeNodeNotReady page fires (the drill checks that it did). The worker is
# always started again on exit, including on failure or Ctrl-C.
#
# Usage: scripts/drills/workload-recovery-drill.sh [worker]   (default tf-ha-worker2)

set -euo pipefail

target="${1:-tf-ha-worker2}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
textfile_dir="${TEXTFILE_DIR:-$HOME/.local/share/kubernetes-in-finance/monitoring/textfile}"
prometheus="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
timeout_s="${DRILL_TIMEOUT:-900}"
drill="workload_node_loss"
ns="kif-drill"
k() { kubectl --kubeconfig "${KUBECONFIG:-$HOME/.kube/kubernetes-in-finance.conf}" "$@"; }
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

for cmd in kubectl multipass jq curl; do
  command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 2; }
done
[[ -d "$textfile_dir" ]] || { echo "textfile directory not found: $textfile_dir (deploy 13-monitoring.yml first)" >&2; exit 2; }

# --- Preflight: refuse to run unless the cluster can absorb the loss --------
workers=$(k get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}')
[[ " $workers " == *" $target "* ]] || { echo "$target is not a worker (workers: $workers)" >&2; exit 2; }
not_ready=$(k get nodes -o json | jq -r '.items[] | select(any(.status.conditions[]; .type=="Ready" and .status!="True")) | .metadata.name')
[[ -z "$not_ready" ]] || { echo "nodes not Ready before the drill: $not_ready" >&2; exit 2; }

k apply -f "$repo/kubernetes/drills/workload-recovery.yaml" >/dev/null
k -n "$ns" rollout status deploy/drill-web --timeout=180s >/dev/null
replicas=$(k -n "$ns" get deploy drill-web -o jsonpath='{.spec.replicas}')
on_target=$(k -n "$ns" get pods -l app=drill-web --field-selector "spec.nodeName=$target" -o name | wc -l)
if [[ "$on_target" -eq 0 ]]; then
  k -n "$ns" rollout restart deploy/drill-web >/dev/null
  k -n "$ns" rollout status deploy/drill-web --timeout=180s >/dev/null
  on_target=$(k -n "$ns" get pods -l app=drill-web --field-selector "spec.nodeName=$target" -o name | wc -l)
fi
if [[ "$on_target" -eq 0 ]]; then
  echo "no drill-web replica on $target; the drill would measure nothing" >&2
  exit 2
fi

# Ready drill pods that are NOT on the powered-off node.
ready_elsewhere() {
  k -n "$ns" get pods -l app=drill-web -o json | jq --arg n "$target" '[.items[]
    | select(.spec.nodeName != $n and .metadata.deletionTimestamp == null)
    | select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))] | length'
}
target_pod_ready() {
  k -n "$ns" get pods -l app=drill-web --field-selector "spec.nodeName=$target" -o json \
    | jq '[.items[] | select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))] | length'
}
node_ready() {
  k get node "$target" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
}

restore_node() {
  if multipass info "$target" 2>/dev/null | grep -q '^State:.*Stopped'; then
    log "starting $target"
    multipass start "$target" || true
  fi
}
trap restore_node EXIT

# --- Inject the failure and record the timeline ------------------------------
log "drill $drill: powering off $target ($on_target of $replicas replicas on it); KubeNodeNotReady will page"
t0=$(date +%s.%N)
multipass stop --force "$target"

elapsed() { echo "$(date +%s.%N) - $t0" | bc; }
t_node_notready="" t_pod_unready="" t_recovered=""
while true; do
  now=$(elapsed)
  if [[ -z "$t_node_notready" && "$(node_ready)" != "True" ]]; then
    t_node_notready=$now; log "node NotReady after ${now%.*} s"
  fi
  if [[ -z "$t_pod_unready" && "$(target_pod_ready)" -eq 0 ]]; then
    t_pod_unready=$now; log "replica on $target removed from Service endpoints after ${now%.*} s"
  fi
  if [[ "$(ready_elsewhere)" -ge "$replicas" ]]; then
    t_recovered=$now; log "full capacity ($replicas Ready replicas on surviving nodes) after ${now%.*} s"
    break
  fi
  if (( $(echo "$now > $timeout_s" | bc) )); then
    log "not recovered within $timeout_s s"
    break
  fi
  sleep 1
done

# Keep the node down until the page fires (time to detect a node loss), at
# most alert_wait seconds after injection. Recovery usually completes first:
# the alert needs 5 minutes of NotReady, recovery needs ~40 s + 300 s.
alert_wait="${ALERT_WAIT:-600}"
alert_fired=0 t_alert=""
log "waiting up to ${alert_wait} s for KubeNodeNotReady to fire"
while (( $(echo "$(elapsed) < $alert_wait" | bc) )); do
  firing=$(curl -fsS --data-urlencode \
    "query=ALERTS{alertname=\"KubeNodeNotReady\",alertstate=\"firing\",node=\"$target\"}" \
    "$prometheus/api/v1/query" 2>/dev/null | jq '.data.result | length' 2>/dev/null || echo 0)
  if [[ "$firing" -ge 1 ]]; then
    alert_fired=1 t_alert=$(elapsed); log "KubeNodeNotReady firing after ${t_alert%.*} s"
    break
  fi
  sleep 10
done
[[ $alert_fired -eq 1 ]] || log "KubeNodeNotReady did not fire within ${alert_wait} s"

restore_node
trap - EXIT
log "waiting for $target to rejoin"
k wait --for=condition=Ready "node/$target" --timeout=300s >/dev/null || log "WARNING: $target not Ready after 5 min"
# Remove the drill workload; the next run re-creates it spread across workers.
k delete namespace "$ns" --wait=false >/dev/null

success=0
[[ -n "$t_recovered" ]] && success=1

tmp="$(mktemp "$textfile_dir/.drill.XXXXXX")"
{
  echo "# HELP platform_drill_last_success 1 if the most recent drill succeeded."
  echo "# TYPE platform_drill_last_success gauge"
  echo "platform_drill_last_success{drill=\"$drill\",host=\"$target\"} $success"
  echo "# HELP platform_drill_last_run_timestamp_seconds When the most recent drill ran."
  echo "# TYPE platform_drill_last_run_timestamp_seconds gauge"
  echo "platform_drill_last_run_timestamp_seconds{drill=\"$drill\",host=\"$target\"} ${t0%.*}"
  echo "# HELP platform_drill_alert_fired 1 if the expected alert fired during the most recent drill."
  echo "# TYPE platform_drill_alert_fired gauge"
  echo "platform_drill_alert_fired{drill=\"$drill\",host=\"$target\",alertname=\"KubeNodeNotReady\"} $alert_fired"
  if [[ $success -eq 1 ]]; then
    echo "# HELP platform_drill_duration_seconds Measured recovery duration in the most recent successful drill."
    echo "# TYPE platform_drill_duration_seconds gauge"
    echo "platform_drill_duration_seconds{drill=\"$drill\",host=\"$target\"} $t_recovered"
    echo "# HELP platform_drill_phase_seconds Seconds from failure injection to each phase of the most recent drill."
    echo "# TYPE platform_drill_phase_seconds gauge"
    [[ -n "$t_node_notready" ]] && echo "platform_drill_phase_seconds{drill=\"$drill\",host=\"$target\",phase=\"node_notready\"} $t_node_notready"
    [[ -n "$t_pod_unready" ]] && echo "platform_drill_phase_seconds{drill=\"$drill\",host=\"$target\",phase=\"endpoint_removed\"} $t_pod_unready"
    echo "platform_drill_phase_seconds{drill=\"$drill\",host=\"$target\",phase=\"recovered\"} $t_recovered"
    [[ -n "$t_alert" ]] && echo "platform_drill_phase_seconds{drill=\"$drill\",host=\"$target\",phase=\"alert_firing\"} $t_alert"
  fi
} >"$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$textfile_dir/drill_${drill}.prom"

summary="node_notready=${t_node_notready:-none}s endpoint_removed=${t_pod_unready:-none}s recovered=${t_recovered:-none}s alert_firing=${t_alert:-none}s"
if [[ $success -eq 1 ]]; then
  echo "drill=$drill host=$target result=success $summary"
else
  echo "drill=$drill host=$target result=FAILED $summary" >&2
  exit 1
fi
