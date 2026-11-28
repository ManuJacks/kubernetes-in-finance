# DR plan: full platform rebuild from backups

| Field | Value |
|---|---|
| Status | **Ready except T4** (fresh Vault backup after the 24-hour check). Tabletop 2026-11-27 and automation 2026-11-28 found 17 gaps (section 8) |
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

New VMs get new DHCP addresses (gap T2). Re-address the repository from
the new VMs before anything else runs against them:

```bash
scripts/readdress.py            # dry run: the old -> new map and a diff
scripts/readdress.py --apply    # rewrite inventory, HAProxy backends, kubeadm template, Prometheus, docs
```

It refuses a map with a missing VM, a duplicate address or a change of zone
subnet. The NFS export and host NAT rules are per subnet and need no change.

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

## 5a. Automation (scripts/dr)

Each phase is a script. **Every state-changing script is a dry run unless
given `--execute`**, and prints exactly what it would run. A test puts fake
`terraform`, `multipass`, `sudo`, `ansible-playbook`, `kubectl`, `vault` and
`gpg` first on `PATH` and fails if a dry run calls any of them.

| Script | Phase | Changes state | Needs the operator for |
|---|---|---|---|
| `00-preflight.sh` | Go/no-go (section 4) | No; starts the run directory | Confirming the MANUAL items |
| `10-capture-before.sh` | 0 | No | |
| `20-destroy.sh --execute` | 1, point of no return | Yes; refuses unless the run's preflight was GO, then asks for a typed phrase | Sudo (Vault) |
| `30-rebuild.sh --execute` | 2 | Yes | |
| `40-restore-cluster.sh --execute` | 3 | Yes | gpg passphrase (cluster PKI), sudo (read the export) |
| `50-restore-vault.sh --execute` | 4 | Yes | sudo, gpg passphrases, 3 of 5 unseal shares |
| `60-verify.sh` | 5 | No (the tests clean up after themselves) | |

Evidence for one exercise goes to
`~/.local/share/kubernetes-in-finance/dr-runs/<run>/`: `preflight.md`,
`before.json`, `after.json`, `verify.md`, `timing.md`, `commands.log` and one
log per test. `capture-state.py` and `compare-state.py` make "recovered"
mean "the same as before": same CA and service-account key, same nodes, every
object by name, the same access model, Vault unsealed, every monitoring target
up.

**Rehearsal 2026-11-28 04:59 UTC** (run `20261128T045918Z`): preflight
NO-GO for the right reasons (T4 open, 24-hour check pending, control2/3 PKI
archives not yet written); before-state captured (310 objects, 18 kinds);
phases 1–4 printed in full as dry runs; phase 5 run for real against the
healthy cluster: **RECOVERED, every check passed** (identities, nodes, all
objects identical, access model, Vault, 15/15 targets, admission guard 27/27,
grant reaper, Vault login 200/403, API via VIP). A verification that passes
on a healthy cluster and fails on each injected regression (tests) is what
makes its result after the DR meaningful.

### Run sheet

```bash
cd ~/Code/kubernetes-in-finance
scripts/dr/00-preflight.sh                 # must print GO
scripts/dr/10-capture-before.sh
scripts/dr/20-destroy.sh                   # read the dry run first
scripts/dr/20-destroy.sh --execute         # point of no return
scripts/dr/30-rebuild.sh --execute
scripts/dr/40-restore-cluster.sh --execute # gpg passphrase
scripts/dr/50-restore-vault.sh --execute   # sudo, passphrases, unseal shares
scripts/dr/60-verify.sh                    # RECOVERED or not
```

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
| T1 | **Cluster PKI was not backed up.** `/etc/kubernetes/pki` (CA, service-account signing key, front-proxy and etcd CAs) exists only on the control-plane VMs. Losing them makes the etcd snapshots restore into a cluster with a new identity: every ServiceAccount token, kubeconfig and the Vault reviewer JWT become invalid | Yes | Encrypted PKI archive written next to every etcd snapshot, to a public key whose private half is held offline | `etcd-backup` role encrypts the CA-level keys with `gpg --recipient-file` beside each snapshot, to the KIF DR backup key | **Closed 2026-11-28.** Live on all three control planes; first archive `cluster-pki-tf-ha-control1-20261128_043515Z.tar.gpg` encrypted to key `3A4B349DEC36404A`, no plaintext, backup status 1. Operator test-decrypt the same day: all 8 files (`ca`, `sa`, `front-proxy-ca`, `etcd/ca`), dated 2026-11-04 (cluster creation), `ca.crt` the same size as the CA Vault trusts |
| T2 | **VM addresses are not stable.** Multipass assigns DHCP addresses; rebuilt VMs get new ones. Addresses are hard-coded in `ansible/inventory/hosts.yml`, `group_vars/load_balancers.yml` (HAProxy backends), `kubeadm-init.yaml.j2` (`advertiseAddress`), `monitoring/prometheus/prometheus.yml`, and become etcd peer URLs and certificate SANs | Yes | Re-address, not pinning (operator decision 2026-11-28): `scripts/readdress.py` maps each node's old address (inventory) to its new one (`multipass list`) and rewrites whole addresses only, in two phases so swaps are safe. History is never rewritten | **Closed 2026-11-28.** 10 tests; simulated rebuild on a copy of the repository: 7 VMs remapped, 8 files rewritten, no old address left, history byte-identical, VIP untouched |
| T3 | **The etcd runbook restores one member in place.** Section 6 stops and restores the local member only. For a three-member cluster on new VMs the snapshot must seed a new single-member cluster, and the other two must join fresh. Never rehearsed | Yes | `17-restore-control-plane.yml` and the etcd runbook's section 7 "Full rebuild": refuses a node with a cluster, checks the restored CA against the before-state **before** touching etcd, restores a single-member cluster, `kubeadm init` on top, removes stale Nodes | **Partly verified 2026-11-28:** the guard (check mode against live control1: refused, nothing changed) and the exact `etcdutl` restore on a real snapshot into a temp dir. `kubeadm init` on restored data and the joins are proven only by the DR itself |
| T4 | **The Vault backup is older than the last Vault change.** USB backup `kif-vault-20261127T054931Z`; `auth/kubernetes/config` was rewritten 2026-11-28T00:15Z. Restoring it brings back the expiring reviewer JWT and every login fails | Yes | New encrypted backup before DR; policy: back up after every Vault change | Needs the operator |
| T5 | **The Vault host is not rebuildable from the repository** (ADR-007 item 8): `vault.hcl` and the package version are only on the host. The systemd unit is the package default | Yes (for phase 4) | `vault-server` role and `16-vault-server.yml`: HashiCorp apt package pinned and held at 2.2.2-1, `vault.hcl` template (renders byte-identical to the live file), directories and ownership, `/etc/hosts` entry, TLS from an operator-supplied directory | **Closed 2026-11-28.** First operator `--check --diff` on the host: `changed=3`, one a real bug (the apt suite came from the Mint codename `zena`, a suite HashiCorp does not publish). After the fix: `changed=1`, only the intended package hold; configuration, TLS, directories and service all `ok`, so the role describes the live host |
| T6 | **The KIF CA private key and the Vault TLS key had no off-host copy.** A full scan of every disk (2026-11-27, `sudo`, null-delimited, self-checked by finding the live key) found them only on the host NVMe: the CA working directory `/root/kif-pki/` (CA key passphrase-protected), the live `/opt/vault/tls/`, and Timeshift snapshots on the same disk. The first version of the scan reported nothing, because `xargs` without `-0` aborts silently on a filename containing a quote; the self-check now makes that a failure, not a clean result | Yes (for phase 4) | Encrypted archive on the USB disk: `kif-dr/kif-host-pki-20261128.tar.gpg` (`root/kif-pki`, `opt/vault/tls`, `etc/vault.d`; SHA-256 `c67b08fa…4e60f5`), encrypted to the KIF DR backup key. CA key passphrase verified against the CA certificate and stored in KeePassXC (`KIF Internal Root CA key`) | **Closed 2026-11-28.** Restore proven: the USB copy of the private key, imported alone into an empty keyring, decrypted the archive and listed all 16 entries |
| T12 | All off-host copies (Vault snapshot, DR key, host PKI archive, KeePassXC) are on **one** USB disk | No | A second copy in another place (second disk, kept elsewhere) | Open |
| T13 | The DR private key's only copies are this host's keyring and the USB disk. Its passphrase is in KeePassXC (`KIF DR backup gpg key`) | No | Covered by T12 | Noted |
| T14 | **Terraform could not create a load balancer.** `load_balancer_vm` referred to `each.value.launch_memory`, which the variable type does not have; any create request failed at plan time ("Unsupported attribute"). `terraform validate` passed, so it went unnoticed | Yes | Use `each.value.memory`; a plan with a create request now succeeds (`1 to add`) | **Closed 2026-11-28** |
| T15 | **The load balancer script refused to rebuild the recorded load balancers.** Their frontend addresses `10.97.3.11` and `.12` were "reserved" for everyone, including the VMs that own them | Yes | `LB_REBUILD=1` allows exactly the recorded address for that name, nothing else; VIP still never allowed. 8 tests | **Closed 2026-11-28** |
| T16 | **A rebuilt load balancer would have had no SSH key** (the node script injects it with cloud-init, the load balancer script did not), so `02-load-balancers.yml` could not configure it | Yes | Same cloud-init key injection as the nodes; tested | **Closed 2026-11-28** |
| T17 | **Every playbook would fail after a rebuild with "REMOTE HOST IDENTIFICATION HAS CHANGED"**: `host_key_checking = True` and `known_hosts` holds the old keys | Yes | `scripts/dr/trust-host-keys.sh` reads each new VM's host key over `multipass exec` (not over SSH, so nothing is trusted on first use) and pins it. Live test against a temporary known_hosts: 7 keys pinned, strict SSH to all 7 succeeded. It also caught its own bug (`multipass exec` read the loop's stdin, pinning only the first VM) | **Closed 2026-11-28** |
| T7 | The load balancers are not in the Terraform lifecycle, and `multipass-load-balancer.sh` has no destroy action: they are deleted with `multipass delete --purge` and rebuilt with the script's `create` | No | Phase 1–2 commands above | Noted |
| T8 | kubeadm drops the API audit flags on rebuild | No | Phase 3 step 7 | Noted |
| T9 | Unknown whether add-on playbooks must run again after an etcd restore (their objects are restored, their pods are not) | No | Decide during the run; record | Open |
| T10 | Vault Kubernetes auth survives only if T1 is closed (same CA and signing key) | — | Follows from T1 | Noted |
| T11 | etcd snapshots on the NFS export hold every Secret unencrypted, readable only by root on the host | No | Accepted for the lab; same trust as the host that runs Vault | Noted |
