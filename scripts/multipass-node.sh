#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-}"
NAME="${2:-}"

# Strict allowlist: this script can only manage these five VMs.
case "$NAME" in
  tf-ha-control1|tf-ha-control2|tf-ha-control3|tf-ha-worker1|tf-ha-worker2)
    ;;
  *)
    echo "ERROR: Refusing to manage unapproved VM name: $NAME" >&2
    exit 1
    ;;
esac

command -v multipass >/dev/null 2>&1 || {
  echo "ERROR: multipass CLI not found" >&2
  exit 1
}

case "$ACTION" in
  create)
    if [[ $# -ne 7 ]]; then
      echo "Usage: $0 create NAME ZONE CPUS MEMORY DISK IMAGE" >&2
      exit 2
    fi

    ZONE="$3"
    CPUS="$4"
    MEMORY="$5"
    DISK="$6"
    IMAGE="$7"

    SSH_PUBLIC_KEY_PATH="${K8S_FINANCE_SSH_PUBLIC_KEY:-$HOME/.ssh/id_ed25519_k8s_finance_ansible.pub}"
    if [[ ! -r "$SSH_PUBLIC_KEY_PATH" ]]; then
      echo "ERROR: SSH public key not readable: $SSH_PUBLIC_KEY_PATH" >&2
      exit 1
    fi
    CLOUD_INIT_FILE="$(mktemp)"
    trap 'rm -f "$CLOUD_INIT_FILE"' EXIT
    {
      echo '#cloud-config'
      echo 'ssh_authorized_keys:'
      printf '  - %s\n' "$(<"$SSH_PUBLIC_KEY_PATH")"
    } > "$CLOUD_INIT_FILE"

    if multipass info "$NAME" >/dev/null 2>&1; then
      echo "ERROR: $NAME already exists. Refusing to overwrite it." >&2
      exit 1
    fi

    if ! multipass zones | awk 'NR > 1 {print $1}' | grep -Fxq "$ZONE"; then
      echo "ERROR: Multipass zone $ZONE is not available." >&2
      exit 1
    fi

    echo "Creating $NAME in $ZONE"
    multipass launch \
      --name "$NAME" \
      --zone "$ZONE" \
      --cpus "$CPUS" \
      --memory "$MEMORY" \
      --disk "$DISK" \
      --cloud-init "$CLOUD_INIT_FILE" \
      "$IMAGE"
    ;;

  destroy)
    if [[ $# -ne 2 ]]; then
      echo "Usage: $0 destroy NAME" >&2
      exit 2
    fi

    if ! multipass info "$NAME" >/dev/null 2>&1; then
      echo "$NAME does not exist or is already unavailable; nothing to do."
      exit 0
    fi

    STATE="$(multipass info "$NAME" | awk -F': *' '$1 == "State" {print $2; exit}')"

    if [[ "$STATE" == "Running" ]]; then
      multipass stop "$NAME"
    fi

    echo "Permanently deleting Terraform-managed VM $NAME"
    multipass delete --purge "$NAME"
    ;;

  resize)
    # In-place memory resize of a worker: drain, stop, resize, start, wait
    # Ready, uncordon. Never replaces the VM. No-op when already at size.
    # Serialized with a lock so Terraform's parallel provisioners cannot take
    # both workers down at once (PRB-2026-11-22-node-memory, action 3).
    if [[ $# -ne 3 ]]; then
      echo "Usage: $0 resize NAME MEMORY   (e.g. 1536M, 2G)" >&2
      exit 2
    fi
    MEMORY="$3"

    to_mib() {
      local value="$1" number unit
      number="$(sed -E 's/^([0-9]+(\.[0-9]+)?).*/\1/' <<<"$value")"
      unit="$(sed -E 's/^[0-9.]+//' <<<"$value" | tr '[:lower:]' '[:upper:]')"
      case "$unit" in
        G|GB|GIB) awk -v n="$number" 'BEGIN { printf "%d", n * 1024 + 0.5 }' ;;
        M|MB|MIB) awk -v n="$number" 'BEGIN { printf "%d", n + 0.5 }' ;;
        *) echo "ERROR: unsupported memory value: $value" >&2; return 1 ;;
      esac
    }

    current="$(multipass get "local.$NAME.memory")"
    current_mib="$(to_mib "$current")"
    target_mib="$(to_mib "$MEMORY")"
    if [[ "$current_mib" -eq "$target_mib" ]]; then
      echo "$NAME already has $current; nothing to do."
      exit 0
    fi

    if [[ "$NAME" != tf-ha-worker* ]]; then
      echo "ERROR: refusing to resize control-plane node $NAME ($current -> $MEMORY); etcd quorum needs a separate procedure." >&2
      exit 1
    fi

    # One node per change, confirmed by name: an unattended multi-node apply
    # fails here instead of taking nodes down (PRB-2026-11-22-hypervisor-spof,
    # action 2).
    if [[ "${KIF_RESIZE_CONFIRM:-}" != "$NAME" ]]; then
      echo "ERROR: resizing $NAME ($current -> $MEMORY) needs KIF_RESIZE_CONFIRM=$NAME (one node per apply; see docs/runbooks/worker-memory-resize.md)." >&2
      exit 1
    fi

    if ! systemctl is-active --quiet snap.multipass.multipassd.service 2>/dev/null && [[ -z "${KIF_SKIP_DAEMON_CHECK:-}" ]]; then
      echo "ERROR: multipassd is not active; refusing to start a resize." >&2
      exit 1
    fi

    KUBECTL=(kubectl --kubeconfig "${KUBECONFIG:-$HOME/.kube/kubernetes-in-finance.conf}")
    lock_file="${XDG_RUNTIME_DIR:-$HOME/.cache}/kif-node-resize.lock"
    mkdir -p "$(dirname "$lock_file")"
    exec 9>"$lock_file"
    echo "Waiting for the resize lock ($lock_file)"
    flock -w 3600 9 || { echo "ERROR: could not acquire resize lock" >&2; exit 1; }

    # Preflight (after the lock, so a previous resize has finished).
    # Every other node must be Ready AND schedulable. A cordoned node is out
    # of service even when Ready: on 2026-11-22 a failed resize left
    # tf-ha-worker2 cordoned and the next resize drained tf-ha-worker1 too
    # (INC-2026-11-22-api-outage-multipassd).
    not_ready="$("${KUBECTL[@]}" get nodes -o json | jq -r --arg n "$NAME" \
      '.items[] | select(.metadata.name != $n)
        | select((.spec.unschedulable // false) or any(.status.conditions[]; .type=="Ready" and .status!="True"))
        | .metadata.name')"
    if [[ -n "$not_ready" ]]; then
      echo "ERROR: other nodes are not Ready or are cordoned ($not_ready); refusing to take $NAME down." >&2
      exit 1
    fi
    delta_mib=$(( target_mib - current_mib ))
    available_mib=$(( $(awk '/^MemAvailable:/ {print $2}' "${KIF_MEMINFO:-/proc/meminfo}") / 1024 ))
    if (( delta_mib > 0 && available_mib < delta_mib + 1024 )); then
      echo "ERROR: host has ${available_mib} MiB available; need ${delta_mib} MiB plus a 1024 MiB margin." >&2
      exit 1
    fi

    echo "Resizing $NAME: $current -> $MEMORY (host available: ${available_mib} MiB)"
    "${KUBECTL[@]}" cordon "$NAME"
    "${KUBECTL[@]}" drain "$NAME" --ignore-daemonsets --delete-emptydir-data --timeout=300s

    # Power off from inside the guest instead of `multipass stop`: on
    # 2026-11-22 multipassd 1.17.2 crashed (SIGSEGV) on the stop request and
    # took every VM's networking with it. Never fall back to `multipass stop`.
    node_ip="$("${KUBECTL[@]}" get node "$NAME" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
    ssh_key="${K8S_FINANCE_SSH_PRIVATE_KEY:-$HOME/.ssh/id_ed25519_k8s_finance_ansible}"
    echo "Powering off $NAME from inside the guest ($node_ip)"
    ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=10 "ubuntu@$node_ip" \
      'sudo systemctl poweroff' || true   # the connection drops as the guest goes down
    stopped=0
    for _ in $(seq 1 60); do
      if multipass info "$NAME" | grep -Eq '^State:[[:space:]]+Stopped'; then stopped=1; break; fi
      sleep 2
    done
    if [[ $stopped -ne 1 ]]; then
      echo "ERROR: $NAME did not reach Stopped within 120 s after a guest poweroff; left cordoned. Not using 'multipass stop' (crash path)." >&2
      exit 1
    fi

    if ! multipass set "local.$NAME.memory=$MEMORY"; then
      echo "ERROR: resize failed; starting $NAME at its previous size (left cordoned)." >&2
      multipass start "$NAME"
      exit 1
    fi
    multipass start "$NAME"
    if ! "${KUBECTL[@]}" wait --for=condition=Ready "node/$NAME" --timeout=300s; then
      echo "ERROR: $NAME not Ready after resize; left cordoned for investigation." >&2
      exit 1
    fi
    "${KUBECTL[@]}" uncordon "$NAME"
    echo "$NAME resized to $(multipass get "local.$NAME.memory") and uncordoned."
    ;;

  *)
    echo "Usage: $0 {create|destroy|resize} ..." >&2
    exit 2
    ;;
esac
