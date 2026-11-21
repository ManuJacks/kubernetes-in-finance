# Runbook: etcd Backup and Disaster Recovery

## 1. Overview
This procedure details how etcd snapshot backups are scheduled, verified, and restored on Kubernetes control-plane nodes in the HA topology.

---

## 2. Automated Backup Configuration

The `etcd-backup` Ansible role installs an automated snapshot mechanism managed by systemd timers on each control-plane node:
- **Script**: `/usr/local/bin/etcd-backup.sh`
- **Service**: `/etc/systemd/system/etcd-backup.service`
- **Timer**: `/etc/systemd/system/etcd-backup.timer`
- **Backup Directory**: `/var/backups/etcd` (permissions `0700`, owner `root:root`)
- **Retention**: 7 days (older snapshots automatically pruned)
- **Schedule**: Daily at 02:00 UTC (customizable via `etcd_backup_schedule`)

### Applying the Playbook
To deploy or update the backup job across all control planes:
```bash
cd ansible
ansible-playbook -i inventory/hosts.yml playbooks/10-etcd-backup.yml
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

## 3. Manual / Local Snapshot Execution

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
   TIMESTAMP=$(date -u +"%Y%m%d_%H%M%SZ")
   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     snapshot save "/var/backups/etcd/etcd-snapshot-${TIMESTAMP}.db"
   ```

3. Secure the snapshot file permissions:
   ```bash
   sudo chmod 0600 "/var/backups/etcd/etcd-snapshot-${TIMESTAMP}.db"
   ```

4. Verify snapshot status and integrity:
   ```bash
   sudo etcdutl snapshot status "/var/backups/etcd/etcd-snapshot-${TIMESTAMP}.db" --write-out=table
   ```

5. Prune backups older than the retention period (e.g. 7 days):
   ```bash
   sudo find /var/backups/etcd -type f -name "etcd-snapshot-*.db" -mtime +7 -print -delete
   ```

---

## 3. Snapshot Verification

Every snapshot taken by the automated job is verified automatically. To verify any snapshot manually using `etcdutl` or `etcdctl`:
```bash
sudo etcdutl snapshot status /var/backups/etcd/etcd-snapshot-<TIMESTAMP>.db --write-out=table
```
Check that:
- Total Key count > 0
- Total Size matches expected storage size
- Revision is non-zero

---

## 4. Disaster Recovery & Restoration Procedure

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
Choose the desired verified snapshot:
```bash
sudo etcdutl snapshot restore /var/backups/etcd/etcd-snapshot-<TIMESTAMP>.db \
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
