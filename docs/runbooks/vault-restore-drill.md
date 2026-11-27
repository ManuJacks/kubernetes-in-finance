# Runbook: Vault backup and restore drill

**Objective:** prove that production Vault can be rebuilt from an encrypted
backup held on separate media, and measure how long that takes, including
the human steps. ADR-007 calls recoverability a principle; this drill is
what makes it a fact.

No restore-time target is set yet. The first runs establish a baseline;
a target follows from measurements, not the other way round.

## What it proves, and what it does not

| Proves | Does not prove |
|---|---|
| The encrypted backup is intact (SHA-256) and decrypts with the recorded passphrase | That the passphrase or the shares survive loss of KeePassXC (keep that database backed up separately) |
| The Raft snapshot restores into a new, empty Vault | Rebuilding the *host*: `/etc/vault.d/vault.hcl`, the TLS key and certificate in `/opt/vault/tls/` and the systemd unit are not in the snapshot |
| 3 of the 5 production shares unseal the restored copy | High availability: production is still one node |
| Auth methods, the `prod-debug` role, policies (diffed against `vault/policies/`), the canary secret and the audit device configuration came back | That secret *values* are correct: only metadata is read, nothing is printed |
| The restored users can log in | That workloads can reach a rebuilt Vault (DNS, TLS, network) |

"Separate media" is a removable USB disk. While plugged into the Vault
host it shares that host's failure domain; it is off-host only once
unplugged and stored elsewhere.

## Design

`scripts/drills/vault-restore-drill.sh`:

- **Isolation.** The restored copy runs in a `hashicorp/vault` container,
  same version as production, with `--network none` and all state on
  tmpfs. A full copy of production secrets therefore can neither be reached
  nor reach the cluster, and disappears when the drill ends (also on
  failure or Ctrl-C). Its listener is plain HTTP on the container's own
  loopback: there is no network for TLS to protect, which is the only
  exception to ADR-007's TLS rule.
- **No plaintext on disk.** `backup` keeps the plaintext snapshot in
  `/dev/shm` (RAM) and shreds it after encryption. `restore` streams the
  decrypted snapshot straight into the container.
- **Temporary barrier with the production layout.** A new Vault must be
  initialised before it accepts a snapshot. The drill initialises it 5/3,
  like production. The self-test showed that with a 1/1 barrier the restored
  copy treats the production shares as a raw key and rejects them.
- **Self-test.** `self-test` runs the same restore path against a throwaway
  source Vault loaded with dummy data and the real `vault/policies/`. It
  needs no secrets or human input, so it can be run after any change to the
  script. Its login policy must grant **no more** than the production
  operator's (`kif-admin`): when it granted metadata `read`, the self-test
  passed a check that production then failed (run 1).

## Running it

Monthly, and after any material Vault change (new auth method, role or
policy). Run in a real terminal, not through an automation tool: it
prompts for secrets.

### 0. Self-test the script (about 20 s)

```bash
scripts/drills/vault-restore-drill.sh self-test
```

### 1. Back up production

Plug in the backup disk. Log in to production Vault with a policy that may
read `sys/storage/raft/snapshot`:

```bash
vault login -method=userpass username=robert
scripts/drills/vault-restore-drill.sh backup "/media/robert/<backup disk>/kif-vault"
```

Choose a new passphrase when gpg asks and store it in KeePassXC under
`KIF Infrastructure/Vault`, next to (not inside) the shares entry.

### 2. Restore it

Use the copy on the backup disk, not a local copy, so the drill tests the
media you would recover from:

```bash
scripts/drills/vault-restore-drill.sh restore "/media/robert/<backup disk>/kif-vault/kif-vault-<timestamp>.snap.gpg"
```

You will be asked, in this order:

1. the backup passphrase (gpg);
2. unseal shares, one at a time, until the copy unseals (3 of 5);
3. your userpass password, which logs in to the *restored copy*. Its token
   stays inside the container.

The script prints PASS/FAIL per check, the phase times and the restore
time, and writes `platform_drill_*{drill="vault_snapshot_restore"}` to the
monitoring textfile directory.

### 3. Afterwards

- Unplug the disk and store it away from the host.
- Record the run below and in
  [VAULT_VALIDATION_RESULTS](../security/VAULT_VALIDATION_RESULTS.md).
- Keep the last three backups; delete older ones from the disk.

## If a check fails

| Failure | Likely cause |
|---|---|
| Checksum mismatch | Media corruption or a partial copy. Take a new backup; check the disk |
| gpg: bad passphrase / decryption failed | The passphrase in KeePassXC does not match this file. Treat as a **backup failure** |
| Still sealed after shares | Wrong shares, or shares from another cluster |
| Policies differ | `vault/policies/` and production have drifted: reconcile (repo is the reviewed source) |
| Role, auth or canary missing | The snapshot predates that configuration, or the source was changed after it was taken |
| A check fails with permission denied | The check needs a capability the operator's policy does not grant: a drill defect, not a backup failure. Fix the check and re-run; the run still counts as failed |

## Results

| Date | Snapshot | Result | Restore time (incl. human steps) | Notes |
|---|---|---|---|---|
| 2026-11-26 | self-test (dummy data) | Success, 6/6 checks | 18 s | First run found the 1/1 barrier problem (fixed) |
| 2026-11-27 | `kif-vault-20261127T054931Z.snap.gpg` (production, USB disk) | **Failed**, 5/6 checks | 258 s (unseal 210 s of it) | Backup, checksum, decryption, restore, unseal with 3 production shares and login all worked. Canary check failed: `kif-admin` may `list` but not `read` secret metadata, so the check was denied. Production lists `smoke-test` under that path, but the restored copy was not shown to contain it. Check changed to a key listing; unseal and password prompts were invisible (stdout to `/dev/null`) and are now shown. Re-run required |
