#!/usr/bin/env bash
# Probe Kubernetes API availability through the load-balanced VIP.
#
# Samples https://<vip>:6443/readyz at a fixed interval and writes one CSV row
# per sample: epoch_ms,http_code,latency_ms. /readyz is readable anonymously
# by default (system:public-info-viewer), so no credentials are needed.
#
# Usage: api-probe.sh <output.csv> <duration-seconds> [vip] [interval-seconds]
# Summarise with: api-probe-summary.sh <output.csv>

set -euo pipefail

out="${1:?output CSV path required}"
duration="${2:?duration in seconds required}"
vip="${3:-10.97.3.100}"
interval="${4:-0.2}"

[[ "$duration" =~ ^[0-9]+$ ]] || { echo "duration must be an integer" >&2; exit 2; }
[[ -e "$out" ]] && { echo "refusing to overwrite $out" >&2; exit 2; }

echo "epoch_ms,http_code,latency_ms" >"$out"
end=$(( $(date +%s) + duration ))
while (( $(date +%s) < end )); do
  start_ms=$(date +%s%3N)
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 1 \
    "https://${vip}:6443/readyz" 2>/dev/null || true)
  [[ -z "$code" ]] && code=000
  echo "${start_ms},${code},$(( $(date +%s%3N) - start_ms ))" >>"$out"
  sleep "$interval"
done
