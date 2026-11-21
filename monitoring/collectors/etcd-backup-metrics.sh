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
