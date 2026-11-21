#!/usr/bin/env bash
# Ensure the host bridge that carries the API VIP network is configured
# correctly (NetworkManager on the engineering workstation).
#
# STP must be OFF. With STP on (NetworkManager's default for bridges), every
# load-balancer VM boot leaves its bridge port blocked for the forward delay
# (15 s). VRRP adverts and gratuitous ARPs are dropped, both load balancers
# claim MASTER, clients keep a stale ARP entry for the VIP, and the API is
# unreachable for ~30-40 s (game day 2026-11-21). The bridge only has VM ports
# and no redundant links, so a forwarding loop is not possible without STP.
#
# Usage: host-frontend-bridge.sh check|ensure
#   check   report and exit non-zero if the bridge is misconfigured
#   ensure  persist the profile and apply it to the live bridge in place
#           (nmcli device reapply; never deactivates the bridge)

set -euo pipefail

BRIDGE="br-api-frontend"
ADDRESS="10.97.3.1/24"

action="${1:-check}"
command -v nmcli >/dev/null || { echo "nmcli not found" >&2; exit 2; }

live_stp() { cat "/sys/class/net/${BRIDGE}/bridge/stp_state" 2>/dev/null || echo missing; }
profile_stp() { nmcli -g bridge.stp connection show "$BRIDGE" 2>/dev/null || echo missing; }

report() {
  echo "bridge=${BRIDGE} profile_stp=$(profile_stp) live_stp_state=$(live_stp) address=$(ip -o -4 addr show dev "$BRIDGE" 2>/dev/null | awk '{print $4}')"
}

case "$action" in
  check)
    report
    [[ "$(profile_stp)" == "no" && "$(live_stp)" == "0" ]] || {
      echo "MISCONFIGURED: STP must be disabled on ${BRIDGE}" >&2
      exit 1
    }
    ;;
  ensure)
    if ! nmcli connection show "$BRIDGE" >/dev/null 2>&1; then
      nmcli connection add type bridge con-name "$BRIDGE" ifname "$BRIDGE" \
        bridge.stp no ipv4.method manual ipv4.addresses "$ADDRESS" ipv6.method disabled
      nmcli connection up "$BRIDGE"
    else
      nmcli connection modify "$BRIDGE" bridge.stp no
      # Apply in place; reapply never tears the bridge down. If the running
      # NetworkManager cannot reapply this property, it fails without changes.
      nmcli device reapply "$BRIDGE"
    fi
    report
    [[ "$(live_stp)" == "0" ]] || { echo "live bridge still has STP enabled" >&2; exit 1; }
    ;;
  *)
    echo "usage: $0 check|ensure" >&2
    exit 2
    ;;
esac
