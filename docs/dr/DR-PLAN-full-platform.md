# DR plan: full platform rebuild from backups

| Field | Value |
|---|---|
| Status | **Draft. Tabletop 2026-11-27 found blocking gaps (section 8); not ready to run** |
| Owner | Operator (robert); executed with Claude |
| Related | [etcd backup and restore](../runbooks/etcd-backup-restore.md), [Vault restore drill](../runbooks/vault-restore-drill.md), [ADR-007](../decisions/ADR-007-external-vault-secrets-management.md), [API audit runbook](../runbooks/apiserver-audit.md) |

## 1. Scenario

Every platform VM is lost: three control planes, two workers, and the two
load balancers (`tf-ha-*`, `api-lb1-new`, `api-lb2-new`). The Vault service is lost too: its
data directory `/opt/vault/data` and its configuration.

What survives, because it is what a real event of this kind leaves:

- the host OS, Multipass, Docker, and this repository;
- the host NFS export `/srv/k8s-etcd-backups` (hourly etcd snapshots and,
  once gap T1 is closed, encrypted cluster PKI);
- the encrypted Vault backup on removable media (USB);
- KeePassXC (`KIF Infrastructure/Vault`): unseal shares, passphrases;
- the host monitoring stack (Prometheus, Alertmanager, Grafana, ntfy).

Out of scope: losing the host itself (that needs an OS rebuild and is the
single failure domain recorded in ADR-007 and PRB-2026-11-22-hypervisor),
the throwaway Jenkins and registry containers.

## 2. Objectives

| Objective | Target | Basis |
|---|---|---|
| RTO: Kubernetes API available through the VIP | 2 h from "go" | One operator, scripted rebuild |
| RTO: workloads Ready, admission guard and grant reaper active | 2 h 30 min | |
| RTO: Vault unsealed, Kubernetes logins work | 3 h | Needs the operator in person |
| RPO: cluster state | 1 h | Hourly etcd snapshots |
| RPO: Vault | Last Vault backup; must be newer than the last Vault change | Gap T4 |

Measured, not estimated: every phase in section 5 records start and end
times in the timing sheet (section 7).

## 3. Roles

| Role | Who | Needed for |
|---|---|---|
| Operator | robert | Go/no-go, USB disk, gpg passphrase, 3 of 5 unseal shares, Vault login, host sudo |
| Executor | Claude | Terraform and Ansible runs, verification, evidence capture, timing |

The operator must be present for phases 0, 4 and the final go/no-go.

## 4. Preconditions (go/no-go)

All must be true. Any "no" stops the exercise before phase 1.

1. Every tabletop gap marked blocking in section 8 is closed.
2. A fresh etcd snapshot from all three members, less than 1 hour old, on
   the NFS export, verified with `etcdutl snapshot status`.
3. The encrypted PKI backup from the same hour exists and has been
   test-decrypted (gap T1).
4. A fresh encrypted Vault backup on the USB disk, taken after the last
   Vault change, with its SHA-256 recorded (gap T4).
5. The KIF CA key and Vault TLS key backups exist and have been located
   (gap T6).
6. The 24-hour Vault login check is done (the DR must not reset it first).
7. Host clock synchronised (`11-time-sync.yml`); host has at least 6 GiB
   free with the old VMs gone (they release their memory first).
8. The operator has blocked out 3 hours and has every credential to hand.

**Point of no return: phase 1.** After the VMs are deleted the only way
back is forward through this plan.

## 5. Procedure

### Phase 0: capture the "before" state (operator present)

- Record `kubectl get nodes,ns`, every production-debug RoleBinding, the
  admission policy generation, `vault status`, Vault auth config readback,
  monitoring targets. This is what "recovered" is compared against.
- Run the backups in preconditions 2–4 and record checksums.

### Phase 1: destroy (point of no return)

```bash
cd terraform && terraform destroy          # five Kubernetes VMs
multipass delete --purge api-lb1-new api-lb2-new   # not in the Terraform lifecycle (T7)
sudo systemctl stop vault && sudo mv /opt/vault/data /opt/vault/data.dr-$(date +%s)
```

Vault's old data is moved aside, not deleted, until phase 6 passes.

### Phase 2: rebuild the VMs and re-address

```bash
terraform apply                             # five Kubernetes VMs
scripts/multipass-load-balancer.sh create api-lb1-new zone2 ...   # arguments from main.tf
scripts/multipass-load-balancer.sh create api-lb2-new zone3 ...
```

New VMs get new DHCP addresses (gap T2). Until T2 is closed, every file in
section 8, T2, must be updated before phase 3.

### Phase 3: Kubernetes from the restored state

1. `01-common.yml`, `02-load-balancers.yml`, `09-host-networking.yml`,
   `11-time-sync.yml`.
2. Restore the cluster PKI to `tf-ha-control1:/etc/kubernetes/pki` from the
   encrypted backup (gap T1).
3. Restore etcd on `tf-ha-control1` only, as a new single-member cluster
   from the newest snapshot (gap T3 procedure):
   `etcdutl snapshot restore <snap> --data-dir /var/lib/etcd
   --name tf-ha-control1 --initial-cluster tf-ha-control1=https://<ip>:2380
   --initial-advertise-peer-urls https://<ip>:2380`.
4. `kubeadm init` on control1 with the restored PKI and data directory
   (`--ignore-preflight-errors=DirAvailable--var-lib-etcd`). kubeadm reuses
   the CA and service-account keys, so every existing token, kubeconfig and
   the Vault reviewer JWT stay valid.
5. Join control2 and control3 (`04`, `07`), then the workers (`08`). They
   join as new etcd members; nothing is restored on them.
6. Do **not** re-run add-on playbooks (`06-cilium`, `06b`, `06c`) blindly:
   their objects are already in etcd. Run them only if their pods do not
   come back (tabletop open question, T9).
7. `15-apiserver-audit.yml` (kubeadm drops the audit flags, runbook
   "Known limit"); `10-etcd-backup.yml`.

### Phase 4: Vault (operator present)

1. Rebuild the Vault host configuration from the repository (gap T5:
   `vault-server` role), install the TLS key and certificate from backup
   (gap T6).
2. Start Vault, restore the Raft snapshot from the USB backup
   (`vault operator raft snapshot restore -force`), unseal with 3 shares.
3. No Kubernetes auth reconfiguration should be needed: the CA, the
   service-account signing key and the reviewer Secret are all restored.
   If logins fail, re-run CHG-2026-11-26 step 3.

### Phase 5: verify

Every check is an existing, scripted test. "Recovered" means all pass.

| Check | Command | Pass |
|---|---|---|
| API through the VIP | blackbox `api-vip` probe, `kubectl get --raw /readyz` | 200 |
| Nodes | `kubectl get nodes` | 5/5 Ready |
| State restored | Phase 0 comparison | Same namespaces, tenants, policy generation, no lost objects newer than RPO |
| Admission guard | `scripts/test-access-guard.sh kubernetes-admin@kubernetes` | 27/27 |
| Grant reaper | `scripts/test-grant-reaper.sh kubernetes-admin@kubernetes` | all pass |
| API audit | runbook "Verify" | grant, revoke and SA reads recorded |
| Vault | `vault status`, `scripts/vault-kubernetes-smoke-test.sh` | unsealed; 200 / 403 |
| Monitoring | every target up, no unexpected alert | `VaultSealed` and burn-rate alerts resolved |

### Phase 6: close out

Remove `/opt/vault/data.dr-*`, write the game-day record and the
post-incident review with the timing sheet, and update this plan with
what was wrong.

## 6. Abort and failure handling

Before phase 1: abort freely. After phase 1 there is no rollback; a failed
step is fixed forward. If the RTO is exceeded by 50 %, stop, record where,
and decide whether to continue tonight or resume later (the cluster is a
lab; the clock is the evidence).

## 7. Timing sheet

| Phase | Start (UTC) | End (UTC) | Duration | Notes |
|---|---|---|---|---|
| 0 Before state and backups | | | | |
| 1 Destroy | | | | |
| 2 Rebuild VMs | | | | |
| 3 Kubernetes restored | | | | API through the VIP = RTO 1 |
| 4 Vault | | | | |
| 5 Verify | | | | |

## 8. Tabletop findings, 2026-11-27

Walked the procedure against the repository and the live lab, without
changing anything.

| # | Finding | Blocking | Fix | Status |
|---|---|---|---|---|
| T1 | **Cluster PKI is not backed up.** `/etc/kubernetes/pki` (CA, service-account signing key, front-proxy and etcd CAs) exists only on the control-plane VMs. Losing them makes the etcd snapshots restore into a cluster with a new identity: every ServiceAccount token, kubeconfig and the Vault reviewer JWT become invalid | Yes | Encrypted PKI archive written next to every etcd snapshot, to a public key whose private half is held offline | `etcd-backup` role encrypts the CA-level keys with `gpg --recipient-file` beside each snapshot (round-trip tested). Off until the operator creates a key pair and sets `etcd_backup_pki_recipient_key` |
| T2 | **VM addresses are not stable.** Multipass assigns DHCP addresses; rebuilt VMs get new ones. Addresses are hard-coded in `ansible/inventory/hosts.yml`, `group_vars/load_balancers.yml` (HAProxy backends), `kubeadm-init.yaml.j2` (`advertiseAddress`), `monitoring/prometheus/prometheus.yml`, and become etcd peer URLs and certificate SANs | Yes | Either pin addresses, or a re-address step that regenerates these from `multipass list` | Decision needed |
| T3 | **The etcd runbook restores one member in place.** Section 6 stops and restores the local member only. For a three-member cluster on new VMs the snapshot must seed a new single-member cluster, and the other two must join fresh. Never rehearsed | Yes | Procedure in phase 3 above; becomes the etcd runbook's "Full rebuild" section once rehearsed | Written here, not rehearsed |
| T4 | **The Vault backup is older than the last Vault change.** USB backup `kif-vault-20261127T054931Z`; `auth/kubernetes/config` was rewritten 2026-11-28T00:15Z. Restoring it brings back the expiring reviewer JWT and every login fails | Yes | New encrypted backup before DR; policy: back up after every Vault change | Needs the operator |
| T5 | **The Vault host is not rebuildable from the repository** (ADR-007 item 8): `vault.hcl` and the package version are only on the host. The systemd unit is the package default | Yes (for phase 4) | `vault-server` role and `16-vault-server.yml`: HashiCorp apt package pinned and held at 2.2.2-1, `vault.hcl` template (renders byte-identical to the live file), directories and ownership, `/etc/hosts` entry, TLS from an operator-supplied directory | Written and linted; operator to run `--check --diff` on the host (needs sudo) and confirm no changes |
| T6 | **Where the KIF CA private key and the Vault TLS key are backed up is not recorded.** Without the TLS key, Vault cannot serve `vault.kif.io`; without the CA key, a new certificate cannot be issued | Yes (for phase 4) | Operator to confirm; record in ADR-007 | Question for the operator |
| T7 | The load balancers are not in the Terraform lifecycle, and `multipass-load-balancer.sh` has no destroy action: they are deleted with `multipass delete --purge` and rebuilt with the script's `create` | No | Phase 1–2 commands above | Noted |
| T8 | kubeadm drops the API audit flags on rebuild | No | Phase 3 step 7 | Noted |
| T9 | Unknown whether add-on playbooks must run again after an etcd restore (their objects are restored, their pods are not) | No | Decide during the run; record | Open |
| T10 | Vault Kubernetes auth survives only if T1 is closed (same CA and signing key) | — | Follows from T1 | Noted |
| T11 | etcd snapshots on the NFS export hold every Secret unencrypted, readable only by root on the host | No | Accepted for the lab; same trust as the host that runs Vault | Noted |
