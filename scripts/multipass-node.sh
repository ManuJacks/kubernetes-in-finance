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

  *)
    echo "Usage: $0 {create|destroy} ..." >&2
    exit 2
    ;;
esac
