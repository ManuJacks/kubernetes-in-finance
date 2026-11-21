#!/bin/sh
# Export etcd backup freshness (RPO) as node_exporter textfile metrics.
# Runs in a small container with the NFS backup export mounted read-only.
# The snapshot file's modification time is used, not the timestamp in its
# name: names are generated from node clocks, which have drifted before.
set -eu

src="${BACKUP_DIR:-/backups}"
out="${TEXTFILE_DIR:-/textfile}/etcd_backup.prom"
interval="${INTERVAL_SECONDS:-60}"

while true; do
  newest=0
  newest_size=0
  count=0
  for f in "$src"/etcd-snapshot-*.db; do
    [ -e "$f" ] || continue
    count=$((count + 1))
    mtime=$(stat -c %Y "$f")
    if [ "$mtime" -gt "$newest" ]; then
      newest=$mtime
      newest_size=$(stat -c %s "$f")
    fi
  done

  tmp="$out.$$"
  {
    # Per-node outcome of the most recent backup attempt, written by
    # etcd-backup.sh as "<unix time> <1|0>" (backup success KPI).
    echo "# HELP etcd_backup_last_run_success 1 if the node's most recent backup attempt succeeded."
    echo "# TYPE etcd_backup_last_run_success gauge"
    echo "# HELP etcd_backup_last_run_timestamp_seconds When the node last attempted a backup."
    echo "# TYPE etcd_backup_last_run_timestamp_seconds gauge"
    for s in "$src"/.etcd-backup-status-*; do
      [ -e "$s" ] || continue
      node=${s##*/.etcd-backup-status-}
      read -r ts ok <"$s" || continue
      case "$node$ts$ok" in *[!a-zA-Z0-9._-]*) continue ;; esac
      echo "etcd_backup_last_run_success{node=\"$node\"} $ok"
      echo "etcd_backup_last_run_timestamp_seconds{node=\"$node\"} $ts"
    done
    echo "# HELP etcd_backup_snapshots Number of etcd snapshot files in the backup store."
    echo "# TYPE etcd_backup_snapshots gauge"
    echo "etcd_backup_snapshots $count"
    echo "# HELP etcd_backup_newest_snapshot_timestamp_seconds Modification time of the newest snapshot."
    echo "# TYPE etcd_backup_newest_snapshot_timestamp_seconds gauge"
    echo "etcd_backup_newest_snapshot_timestamp_seconds $newest"
    echo "# HELP etcd_backup_newest_snapshot_bytes Size of the newest snapshot."
    echo "# TYPE etcd_backup_newest_snapshot_bytes gauge"
    echo "etcd_backup_newest_snapshot_bytes $newest_size"
    echo "# HELP etcd_backup_collector_last_run_timestamp_seconds When this collector last ran."
    echo "# TYPE etcd_backup_collector_last_run_timestamp_seconds gauge"
    echo "etcd_backup_collector_last_run_timestamp_seconds $(date +%s)"
  } >"$tmp"
  mv "$tmp" "$out"
  sleep "$interval"
done
