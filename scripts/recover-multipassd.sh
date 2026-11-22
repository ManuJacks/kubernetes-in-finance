#!/usr/bin/env bash
# Recover from a multipassd crash that leaves VMs running but disconnected
# (INC-2026-11-22-api-outage-multipassd, runbook docs/runbooks/multipassd-crash.md).
#
# Symptoms: `multipass list` cannot connect; multipassd fails to start with
# "dnsmasq died ... port 53" or "Failed to get shared write lock"; the
# mpqemubrzone* bridges are DOWN or missing; VMs unreachable.
#
# Stops orphaned dnsmasq and QEMU processes (workers, control planes, then
# load balancers; a hard power-off from the guest's view), then starts
# multipassd, which rebuilds the bridges and restarts the VMs that were
# running. Refuses to act while multipassd is healthy.
#
# Usage: sudo scripts/recover-multipassd.sh [--yes]

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
UNIT=snap.multipass.multipassd.service

if systemctl is-active --quiet "$UNIT"; then
  echo "multipassd is active; this script is only for a crashed daemon. Nothing done." >&2
  exit 1
fi

instance_of() { tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | grep -oE 'instances/[^/]+/' | head -1 | cut -d/ -f2; }

mapfile -t qemu_pids < <(pgrep -f '/snap/multipass/.*/qemu-system-x86_64' || true)
mapfile -t dnsmasq_pids < <(pgrep -f '/snap/multipass/.*/dnsmasq' || true)

# Order: workers, control planes, everything else (load balancers last).
ordered=()
for pattern in 'worker' 'control' '.'; do
  for pid in "${qemu_pids[@]}"; do
    name="$(instance_of "$pid")"
    [[ -n "$name" && "$name" =~ $pattern ]] || continue
    [[ " ${ordered[*]} " == *" $pid:"* ]] && continue
    ordered+=("$pid:$name")
  done
done

echo "Orphaned dnsmasq: ${dnsmasq_pids[*]:-none}"
echo "Orphaned VMs (stop order):"
for entry in "${ordered[@]}"; do echo "  ${entry#*:} (pid ${entry%%:*})"; done
if [[ "${1:-}" != "--yes" ]]; then
  read -r -p "Hard-stop these and restart multipassd? Type 'recover': " answer
  [[ "$answer" == "recover" ]] || { echo "Nothing done."; exit 1; }
fi

for pid in "${dnsmasq_pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done

for entry in "${ordered[@]}"; do
  pid="${entry%%:*}"; name="${entry#*:}"
  [[ -e /proc/$pid ]] || continue
  [[ "$(instance_of "$pid")" == "$name" ]] || { echo "ABORT: pid $pid changed identity" >&2; exit 1; }
  echo "Stopping $name (pid $pid)"
  kill -TERM "$pid"
  for _ in $(seq 1 30); do [[ -e /proc/$pid ]] || break; sleep 1; done
  [[ -e /proc/$pid ]] && { echo "  KILL $name"; kill -KILL "$pid"; sleep 2; }
done

if pgrep -f '/snap/multipass/.*/(qemu-system-x86_64|dnsmasq)' >/dev/null; then
  echo "ABORT: multipass processes still running:" >&2
  pgrep -af '/snap/multipass/.*/(qemu-system-x86_64|dnsmasq)' >&2
  exit 1
fi

systemctl reset-failed "$UNIT"
systemctl start "$UNIT"
for _ in $(seq 1 60); do systemctl is-active --quiet "$UNIT" && break; sleep 2; done
systemctl is-active "$UNIT"
ip -br addr | grep -E 'mpqemubr|br-api' || true
echo "Next, as your user: multipass list; then verify per docs/runbooks/multipassd-crash.md."
