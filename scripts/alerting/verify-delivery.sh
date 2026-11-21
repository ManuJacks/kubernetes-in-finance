#!/usr/bin/env bash
# End-to-end alert delivery check: inject a synthetic alert into Alertmanager,
# then confirm ntfy received it. Proves routing, the webhook and the topic
# work; does not exercise Prometheus rule evaluation (promtool tests do).
#
# Usage: scripts/alerting/verify-delivery.sh [page|ticket]
# The synthetic alert expires after 2 minutes; ntfy sends a "resolved"
# notification when it does.

set -euo pipefail

severity="${1:-ticket}"
[[ "$severity" == page || "$severity" == ticket ]] || { echo "usage: $0 [page|ticket]" >&2; exit 2; }
secrets="${MONITORING_HOME:-$HOME/.local/share/kubernetes-in-finance/monitoring}/secrets"
am="${ALERTMANAGER_URL:-http://127.0.0.1:9093}"
ntfy="${NTFY_SERVER:-https://ntfy.sh}"
topic="kif-$(cat "$secrets/ntfy-topic")"
marker="delivery-check-$(date +%s)"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ends=$(date -u -d '+2 minutes' +%Y-%m-%dT%H:%M:%SZ)
since=$(date +%s)

curl -fsS -X POST "$am/api/v2/alerts" -H 'Content-Type: application/json' -d "[{
  \"labels\": {\"alertname\": \"AlertDeliveryCheck\", \"severity\": \"$severity\", \"check\": \"$marker\"},
  \"annotations\": {\"summary\": \"Synthetic alert: delivery check ($severity). No action needed.\", \"runbook\": \"docs/monitoring/README.md\"},
  \"startsAt\": \"$now\", \"endsAt\": \"$ends\"}]" >/dev/null

# group_wait is 30 s; allow up to 90 s for delivery.
for _ in $(seq 1 18); do
  sleep 5
  if curl -fsS "$ntfy/$topic/json?poll=1&since=$since" | grep -q "AlertDeliveryCheck"; then
    echo "delivered: AlertDeliveryCheck severity=$severity reached ntfy in about $(( $(date +%s) - since )) s"
    exit 0
  fi
done
echo "NOT delivered within 90 s; check Alertmanager logs and alertmanager_notifications_failed_total" >&2
exit 1
