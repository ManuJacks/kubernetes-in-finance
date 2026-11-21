#!/usr/bin/env bash
# Isolated etcd restore drill (docs/runbooks/etcd-backup-restore.md) with
# timing, exported as Prometheus textfile metrics: RTO evidence.
#
# Restores the newest snapshot into a temporary data directory on one
# control-plane node. The live etcd member is never stopped or touched.
# A failed drill is recorded as a failure (platform_drill_last_success 0).
#
# Usage: scripts/drills/etcd-restore-drill.sh [control-plane-host]

set -euo pipefail

host="${1:-tf-ha-control1}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
textfile_dir="${TEXTFILE_DIR:-$HOME/.local/share/kubernetes-in-finance/monitoring/textfile}"
drill="etcd_isolated_restore"

[[ -d "$textfile_dir" ]] || { echo "textfile directory not found: $textfile_dir (deploy 13-monitoring.yml first)" >&2; exit 2; }

# Single-quoted on purpose: expands on the control-plane node, not locally.
# shellcheck disable=SC2016
remote_script='set -euo pipefail
SNAPSHOT=$(find /var/backups/etcd -maxdepth 1 -type f -name "etcd-snapshot-*.db" -printf "%T@ %p\n" | sort -nr | head -1 | cut -d" " -f2-)
test -n "$SNAPSHOT"
RESTORE_DIR=$(mktemp -d /tmp/etcd-restore-drill.XXXXXX)
trap "rm -rf \"$RESTORE_DIR\"" EXIT
start=$(date +%s.%N)
etcdutl snapshot restore "$SNAPSHOT" --data-dir="$RESTORE_DIR/data" >/dev/null 2>&1
end=$(date +%s.%N)
test -d "$RESTORE_DIR/data/member/wal" && test -d "$RESTORE_DIR/data/member/snap"
keys=$(etcdutl snapshot status "$SNAPSHOT" --write-out=json | jq -r .totalKey)
test "$keys" -gt 0
echo "DRILL snapshot=$(basename "$SNAPSHOT") keys=$keys duration=$(echo "$end - $start" | bc)"'

started=$(date +%s)
set +e
output=$(cd "$repo" && ANSIBLE_CONFIG=ansible/ansible.cfg timeout 300 \
  ansible "$host" -i ansible/inventory/hosts.yml -m ansible.builtin.shell \
  -a "$remote_script" -e ansible_shell_executable=/bin/bash 2>&1)
rc=$?
set -e

result=$(grep -oE 'DRILL .*' <<<"$output" | tail -1 || true)
duration=$(sed -nE 's/.*duration=([0-9.]+).*/\1/p' <<<"$result")
keys=$(sed -nE 's/.*keys=([0-9]+).*/\1/p' <<<"$result")
success=0
if [[ $rc -eq 0 && -n "$duration" && -n "$keys" ]]; then
  success=1
fi

tmp="$(mktemp "$textfile_dir/.drill.XXXXXX")"
{
  echo "# HELP platform_drill_last_success 1 if the most recent drill succeeded."
  echo "# TYPE platform_drill_last_success gauge"
  echo "platform_drill_last_success{drill=\"$drill\",host=\"$host\"} $success"
  echo "# HELP platform_drill_last_run_timestamp_seconds When the most recent drill ran."
  echo "# TYPE platform_drill_last_run_timestamp_seconds gauge"
  echo "platform_drill_last_run_timestamp_seconds{drill=\"$drill\",host=\"$host\"} $started"
  if [[ $success -eq 1 ]]; then
    echo "# HELP platform_drill_duration_seconds Measured restore duration in the most recent successful drill."
    echo "# TYPE platform_drill_duration_seconds gauge"
    echo "platform_drill_duration_seconds{drill=\"$drill\",host=\"$host\"} $duration"
    echo "# HELP platform_drill_restored_keys Keys in the restored snapshot."
    echo "# TYPE platform_drill_restored_keys gauge"
    echo "platform_drill_restored_keys{drill=\"$drill\",host=\"$host\"} $keys"
  fi
} >"$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$textfile_dir/drill_${drill}.prom"

if [[ $success -eq 1 ]]; then
  echo "drill=$drill host=$host result=success ${result#DRILL }"
else
  echo "drill=$drill host=$host result=FAILED (exit $rc)" >&2
  tail -5 <<<"$output" >&2
  exit 1
fi
