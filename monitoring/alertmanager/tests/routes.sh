#!/bin/sh
# Routing tests: each label set must reach exactly the expected receiver.
# Usage (inside the Alertmanager image): sh routes.sh /etc/alertmanager/alertmanager.yml
set -eu
config="$1"
fail=0

expect() {
  receiver="$1"
  shift
  got=$(amtool config routes test --config.file="$config" "$@")
  if [ "$got" = "$receiver" ]; then
    echo "ok   $* -> $got"
  else
    echo "FAIL $* -> $got (expected $receiver)"
    fail=1
  fi
}

expect ntfy-page alertname=ApiAvailabilityFastBurn severity=page
expect ntfy-page alertname=EtcdBackupRPOAtRisk severity=page
expect ntfy-ticket alertname=EtcdBackupFailed severity=ticket
expect ntfy-ticket alertname=PlatformDrillOverdue severity=ticket
# Anything unlabelled must still reach a human, not be dropped.
expect ntfy-ticket alertname=Unclassified

exit "$fail"
