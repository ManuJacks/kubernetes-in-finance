# Runbook: etcd Backup and Disaster Recovery

## 1. Overview
This procedure details how etcd snapshot backups are scheduled, verified, mounted via external/NFS storage, and restored on Kubernetes control-plane nodes in the HA topology.

---

## 2. Automated Backup Configuration

The `etcd-backup` Ansible role installs an automated snapshot mechanism managed by systemd timers on each control-plane node:
- **Script**: `/usr/local/bin/etcd-backup.sh`
- **Service**: `/etc/systemd/system/etcd-backup.service`
- **Timer**: `/etc/systemd/system/etcd-backup.timer`
- **Backup Directory**: `/var/backups/etcd` (permissions `0700`, owner `root:root`)
- **Retention**: 7 days (older snapshots automatically pruned per node)
- **Schedule**: Daily at 02:00 UTC (customizable via `etcd_backup_schedule`)
- **Naming Convention**: `etcd-snapshot-<node_name>-<YYYYMMDD_HHMMSSZ>.db`
- **Storage warning**: the current NFS target is off-VM but still shares the
  physical Multipass host; it is not protection from host loss.

### Applying the Playbook
To deploy or update the backup job across all control planes:
```bash
cd ansible
ANSIBLE_CONFIG=ansible.cfg ansible-playbook -i inventory/hosts.yml playbooks/10-etcd-backup.yml
```

### Checking Timer and Job Status
On any control-plane node:
```bash
# Check timer status
systemctl status etcd-backup.timer
systemctl list-timers --all | grep etcd-backup

# Check last execution logs
journalctl -u etcd-backup.service --no-pager -n 50
```

### Triggering an Ad-hoc Backup
To run an immediate snapshot outside the schedule:
```bash
sudo systemctl start etcd-backup.service
```
Or run the script directly:
```bash
sudo /usr/local/bin/etcd-backup.sh
```

---

## 3. External & NFS Storage Configuration (Localhost / Remote NAS)

To survive total VM loss or simulate production off-node storage, you can mount `/var/backups/etcd` to an external NFS server (e.g. your local Linux workstation, TrueNAS, or cloud storage like AWS EFS).

### Setting up the Host NFS Server (Workstation / Homelab)

1. **Install NFS server on your physical host**:
   ```bash
   sudo apt-get update && sudo apt-get install -y nfs-kernel-server
   ```

2. **Create the shared backup directory**:
   ```bash
   sudo mkdir -p /srv/nfs/k8s-backups
   sudo chown -R nobody:nogroup /srv/nfs/k8s-backups
   sudo chmod 777 /srv/nfs/k8s-backups
   ```

3. **Export the share for the Multipass VM subnet**:
   Identify the Multipass subnet (e.g. `10.x.x.0/24`) and add an entry to `/etc/exports`:
   ```text
   /srv/nfs/k8s-backups 10.0.0.0/8(rw,sync,no_subtree_check,no_root_squash)
   ```
   Apply the exports:
   ```bash
   sudo exportfs -ra
   sudo systemctl restart nfs-kernel-server
   ```

### Enabling NFS in Ansible

Enable NFS in `ansible/inventory/hosts.yml` or `ansible/roles/etcd-backup/defaults/main.yml`:

```yaml
etcd_backup_use_nfs: true
etcd_backup_nfs_server: "10.0.4.1" # Host machine IP reachable by VMs
etcd_backup_nfs_export: "/srv/nfs/k8s-backups"
etcd_backup_nfs_mount_opts: "rw,sync,hard,intr"
```

Re-run the playbook:
```bash
cd ansible
ANSIBLE_CONFIG=ansible.cfg ansible-playbook -i inventory/hosts.yml playbooks/10-etcd-backup.yml
```

The role will:
1. Install `nfs-common` on the control-plane nodes.
2. Mount the NFS export at `/var/backups/etcd` in `/etc/fstab`.
3. Enable safety guardrails: `etcd-backup.sh` verifies `mountpoint -q /var/backups/etcd` before snapshotting, preventing writing locally if external storage disconnects.

---

## 4. Manual / Local Snapshot Execution

If you need to manually take a backup directly on a control-plane node or in a local testing environment without running the systemd service:

### Prerequisites
1. `etcdctl` and `etcdutl` installed in `$PATH` (e.g., `/usr/local/bin`).
2. Cluster certificates (`ca.crt`, `server.crt`, `server.key`).
3. Root or sudo privileges to access certificates and the backup destination.

### Step-by-Step Manual Execution

1. Create a dedicated backup destination directory:
   ```bash
   sudo mkdir -p /var/backups/etcd
   sudo chmod 0700 /var/backups/etcd
   ```

2. Generate a timestamped snapshot:
   ```bash
   NODE_NAME=$(hostname -s)
   TIMESTAMP=$(date -u +"%Y%m%d_%H%M%SZ")
   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     snapshot save "/var/backups/etcd/etcd-snapshot-${NODE_NAME}-${TIMESTAMP}.db"
   ```

3. Secure the snapshot file permissions:
   ```bash
   sudo chmod 0600 "/var/backups/etcd/etcd-snapshot-${NODE_NAME}-${TIMESTAMP}.db"
   ```

4. Verify snapshot status and integrity:
   ```bash
   sudo etcdutl snapshot status "/var/backups/etcd/etcd-snapshot-${NODE_NAME}-${TIMESTAMP}.db" --write-out=table
   ```

5. Prune backups for this node older than the retention period (e.g. 7 days):
   ```bash
   sudo find /var/backups/etcd -type f -name "etcd-snapshot-${NODE_NAME}-*.db" -mtime +7 -print -delete
   ```

---

## 5. Snapshot Verification

Every snapshot taken by the automated job is verified automatically. To verify any snapshot manually using `etcdutl` or `etcdctl`:
```bash
sudo etcdutl snapshot status /var/backups/etcd/etcd-snapshot-<NODE_NAME>-<TIMESTAMP>.db --write-out=table
```
Check that:
- Total Key count > 0
- Total Size matches expected storage size
- Revision is non-zero

### Isolated Restore Test

Snapshot status is necessary but does not prove that a snapshot can be used
for recovery. Perform this test periodically on a control-plane node using a
temporary data directory. Do not use `/var/lib/etcd`, stop the live etcd
member, or move the restored data into a live manifest path:

```bash
SNAPSHOT=$(sudo find /var/backups/etcd -maxdepth 1 -type f \
  -name 'etcd-snapshot-*.db' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)
RESTORE_DIR=$(sudo mktemp -d /tmp/etcd-restore-audit.XXXXXX)
sudo etcdutl snapshot restore "$SNAPSHOT" --data-dir="$RESTORE_DIR/data"
sudo etcdutl snapshot status "$SNAPSHOT" --write-out=table
sudo rm -rf "$RESTORE_DIR"
```

Record the snapshot name, revision, key count, restore exit status, and test
date as recovery evidence. The test must stop and investigate if the snapshot
is missing, unreadable, has zero keys/revision, or restore returns non-zero.

### Operational Recommendations

- Alert on failed `etcd-backup.service` executions and stale timer success.
- Keep a second destination outside the Multipass physical host for host-loss
  recovery.
- Restrict the NFS export to the control-plane subnet and avoid broad writable
  exports or `no_root_squash` unless a documented compatibility requirement
  exists.
- The default daily schedule and seven-day retention imply roughly a 24-hour
  recovery point objective and seven-day recovery window; confirm those values
  against the event requirements.

---

## 6. Disaster Recovery & Restoration Procedure

> [!CAUTION]
> Restoring etcd replaces cluster state. Follow this sequence strictly during a disaster recovery scenario.

### Step 1: Stop kube-apiserver and etcd
On the control plane node being restored, temporarily remove manifests from the static pod directory:
```bash
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sudo mv /etc/kubernetes/manifests/etcd.yaml /tmp/
```
Wait a few seconds and ensure the etcd container has stopped:
```bash
sudo crictl ps --name etcd
```

### Step 2: Backup Existing Data Directory
```bash
sudo mv /var/lib/etcd /var/lib/etcd-backup-$(date +%s)
```

### Step 3: Restore the Snapshot
Choose the desired verified snapshot (from `/var/backups/etcd` or external NFS storage):
```bash
sudo etcdutl snapshot restore /var/backups/etcd/etcd-snapshot-<NODE_NAME>-<TIMESTAMP>.db \
  --data-dir=/var/lib/etcd
```

Verify permissions of the restored directory:
```bash
sudo chown -R root:root /var/lib/etcd
```

### Step 4: Restart etcd and kube-apiserver
Move the manifests back to the static pod directory:
```bash
sudo mv /tmp/etcd.yaml /etc/kubernetes/manifests/
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
```

### Step 5: Verify Cluster Health
```bash
kubectl get nodes
kubectl get pods -A
ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://127.0.0.1:2379 endpoint health
```
