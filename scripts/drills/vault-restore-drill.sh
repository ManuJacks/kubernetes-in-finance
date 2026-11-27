#!/usr/bin/env bash
# Vault backup and restore drill (ADR-007: recoverability).
#
#   backup  DEST_DIR   Snapshot production Vault, encrypt it (gpg AES256,
#                      passphrase) and write it with a SHA-256 to DEST_DIR,
#                      normally a removable disk. Plaintext only in /dev/shm.
#   restore FILE.gpg   Restore that encrypted snapshot into an isolated Vault
#                      container and prove the data came back. Timed.
#   self-test          Same restore path against a throwaway source Vault with
#                      dummy data: no production secrets, no human input.
#
# Isolation: the restore container has no network (--network none) and keeps
# all state on tmpfs, so the restored copy of production can neither be
# reached nor reach the cluster, and disappears on exit. Its listener is
# plain HTTP on the container's loopback only; TLS has no wire to protect.
#
# Human steps in `restore` (run it in a real terminal): the backup passphrase,
# 3 of the 5 production unseal shares, and a userpass login to the restored
# copy. Nothing typed is printed or stored outside the container.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image="${VAULT_DRILL_IMAGE:-hashicorp/vault:2.2.2}"
ct="kif-vault-restore-drill"
src_ct="kif-vault-restore-selftest-src"
textfile_dir="${TEXTFILE_DIR:-$HOME/.local/share/kubernetes-in-finance/monitoring/textfile}"
login_user="${VAULT_DRILL_USER:-robert}"
canary="secret/production-debug/application/smoke-test"
drill="vault_snapshot_restore"

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
now() { date +%s; }
for cmd in docker gpg jq sha256sum shred; do command -v "$cmd" >/dev/null || die "missing $cmd"; done

# --- Isolated Vault container -----------------------------------------------
start_isolated() { # name node_id
  docker rm -f "$1" >/dev/null 2>&1 || true
  docker run -d --name "$1" --network none \
    --tmpfs /vault/raft:rw,mode=1777 --tmpfs /var/log/vault:rw,mode=1777 --tmpfs /tmp:rw,mode=1777 \
    -e SKIP_SETCAP=true -e VAULT_ADDR=http://127.0.0.1:8200 \
    -e VAULT_LOCAL_CONFIG="$(jq -cn --arg node "$2" '{
        storage: {raft: {path: "/vault/raft", node_id: $node}},
        listener: [{tcp: {address: "127.0.0.1:8200", tls_disable: true}}],
        api_addr: "http://127.0.0.1:8200", cluster_addr: "https://127.0.0.1:8201",
        disable_mlock: true, ui: false}')" \
    "$image" server >/dev/null
  for _ in $(seq 60); do
    # vault status: 0 unsealed, 2 sealed (both mean the server answers).
    rc=0; docker exec "$1" vault status >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 0 || $rc -eq 2 ]] && return 0
    sleep 1
  done
  docker logs "$1" 2>&1 | tail -20 >&2; die "$1 did not start"
}
sealed() { docker exec "$1" vault status -format=json 2>/dev/null | jq -r .sealed; }
wait_active() { # name token
  for _ in $(seq 60); do
    docker exec -e VAULT_TOKEN="$2" "$1" vault read -format=json sys/leader 2>/dev/null \
      | jq -e '.data.is_self' >/dev/null && return 0
    sleep 1
  done
  die "$1 did not become active"
}
init_temp() { # name -> line 1 root token, lines 2-4 three unseal keys of a throwaway barrier.
  # Same 5/3 Shamir layout as production: with a 1/1 barrier the restored
  # copy treats the production shares as a raw key and rejects them.
  docker exec "$1" vault operator init -key-shares=5 -key-threshold=3 -format=json \
    | jq -r '.root_token, .unseal_keys_b64[0:3][]'
}

cleanup() {
  [[ -n "${plain:-}" && -e "$plain" ]] && shred -u "$plain"
  [[ -n "${dir:-}" && -d "$dir" ]] && { find "$dir" -type f -exec shred -u {} +; rm -rf "$dir"; }
  docker rm -f "$ct" "$src_ct" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- Checks against the restored copy (token stored inside the container) ----
results=(); failed=0
check() { # name command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then results+=("PASS  $name"); else results+=("FAIL  $name"); failed=1; fi
}
vx() { docker exec "$ct" vault "$@"; }
c_unsealed()  { [[ "$(sealed "$ct")" == false ]]; }
c_auth()      { vx auth list -format=json | jq -e 'has("kubernetes/") and has("userpass/")'; }
c_policies()  {
  local f p
  for f in "$repo"/vault/policies/*.hcl; do
    p="$(basename "$f" .hcl)"
    diff <(vx policy read "$p") "$f" || return 1
  done
}
c_role()      {
  vx read -format=json auth/kubernetes/role/prod-debug | jq -e '.data
    | .bound_service_account_names == ["prod-debug-sa"]
    and .bound_service_account_namespaces == ["debug-system"]
    and .token_policies == ["production-debug-secrets"] and .token_ttl == 900'
}
# Listing the parent shows key names only: no values, no metadata. kif-admin
# may list but not read secret metadata, so a metadata read would be denied.
c_canary()    { vx kv list -format=json "${canary%/*}" | jq -e --arg k "${canary##*/}" 'index($k) != null'; }
c_audit()     { vx audit list -format=json | jq -e 'length >= 1'; }

# --- Restore ------------------------------------------------------------------
# Globals for self-test: passphrase_fd, unseal_keys (array), login_password.
restore_drill() { # file.gpg
  local file="$1" t0 t_started t_decrypted t_restored t_unsealed t_login t_verified key root k
  [[ -r "$file" ]] || die "not readable: $file"
  if [[ -r "$file.sha256" ]]; then
    (cd "$(dirname "$file")" && sha256sum -c --quiet "$(basename "$file").sha256") || die "checksum mismatch: $file"
    log "checksum OK"
  else
    log "WARNING: no $file.sha256; integrity not checked"
  fi

  t0=$(now)
  log "starting isolated Vault ($image, no network, tmpfs only)"
  start_isolated "$ct" drill-restore-01
  local temp; mapfile -t temp < <(init_temp "$ct"); root="${temp[0]}"
  for key in "${temp[@]:1}"; do docker exec "$ct" vault operator unseal "$key" >/dev/null; done
  unset temp
  wait_active "$ct" "$root"
  t_started=$(now)

  log "decrypting snapshot straight into the container (passphrase prompt)"
  if [[ -n "${passphrase_fd:-}" ]]; then
    gpg --batch --quiet --passphrase-fd "$passphrase_fd" --decrypt "$file"
  else
    gpg --quiet --no-symkey-cache --decrypt "$file"
  fi | docker exec -i "$ct" sh -c 'cat > /tmp/restore.snap'
  t_decrypted=$(now)

  log "restoring snapshot (-force: it comes from another cluster)"
  docker exec -e VAULT_TOKEN="$root" "$ct" vault operator raft snapshot restore -force /tmp/restore.snap
  docker exec "$ct" rm -f /tmp/restore.snap
  unset key root
  t_restored=$(now)

  for _ in $(seq 15); do [[ "$(sealed "$ct")" == true ]] && break; sleep 1; done
  if [[ "$(sealed "$ct")" == true ]]; then
    log "restored copy is sealed with the SOURCE keys: unseal with 3 of 5 shares"
    if [[ -n "${unseal_keys+x}" ]]; then
      for k in "${unseal_keys[@]}"; do docker exec "$ct" vault operator unseal "$k" >/dev/null; done
    else
      local n=1
      while [[ "$(sealed "$ct")" == true ]]; do
        echo ">>> Unseal share $n of 3: paste it and press Enter (input is hidden)" >&2
        docker exec -it "$ct" vault operator unseal >/dev/null; n=$((n + 1))
      done
    fi
  else
    log "restored copy did not seal (unexpected, recorded)"
  fi
  [[ "$(sealed "$ct")" == false ]] || die "restored copy is still sealed"
  for _ in $(seq 60); do docker exec "$ct" vault read sys/leader >/dev/null 2>&1 && break; sleep 1; done
  t_unsealed=$(now)

  log "log in to the restored copy as $login_user (its own users, restored from the snapshot)"
  if [[ -n "${login_password:-}" ]]; then
    docker exec "$ct" vault login -method=userpass username="$login_user" password="$login_password" >/dev/null
  else
    echo ">>> Password for $login_user on the RESTORED copy (input is hidden)" >&2
    docker exec -it "$ct" vault login -no-print -method=userpass username="$login_user"
  fi
  t_login=$(now)

  check "restored copy is unsealed"                       c_unsealed
  check "auth methods kubernetes/ and userpass/ restored"  c_auth
  check "policies identical to vault/policies/"            c_policies
  check "role prod-debug bound to debug-system/prod-debug-sa, 900 s" c_role
  check "canary secret $canary present (key name only)"    c_canary
  check "audit device configuration restored"              c_audit
  t_verified=$(now)

  echo
  echo "== Vault restore drill: $(date -Is)"
  echo "snapshot: $(basename "$file")"
  printf '%s\n' "${results[@]}"
  echo "phase seconds (from start): started=$((t_started - t0)) decrypted=$((t_decrypted - t0))" \
       "restored=$((t_restored - t0)) unsealed=$((t_unsealed - t0)) logged_in=$((t_login - t0)) verified=$((t_verified - t0))"
  echo "restore time (RTO, incl. human steps): $((t_verified - t0)) s"
  echo "result: $([[ $failed -eq 0 ]] && echo SUCCESS || echo FAILED)"

  if [[ -z "${selftest:-}" ]]; then
    if [[ -d "$textfile_dir" ]]; then
      local tmp success=$((1 - failed))
      tmp="$(mktemp "$textfile_dir/.vault-restore.XXXXXX")"
      {
        echo "# HELP platform_drill_last_success 1 if the most recent drill succeeded."
        echo "# TYPE platform_drill_last_success gauge"
        echo "platform_drill_last_success{drill=\"$drill\",host=\"kif-vault-01\"} $success"
        echo "# HELP platform_drill_last_run_timestamp_seconds When the most recent drill ran."
        echo "# TYPE platform_drill_last_run_timestamp_seconds gauge"
        echo "platform_drill_last_run_timestamp_seconds{drill=\"$drill\",host=\"kif-vault-01\"} $t0"
        if [[ $success -eq 1 ]]; then
          echo "# HELP platform_drill_duration_seconds Measured recovery duration in the most recent successful drill."
          echo "# TYPE platform_drill_duration_seconds gauge"
          echo "platform_drill_duration_seconds{drill=\"$drill\",host=\"kif-vault-01\"} $((t_verified - t0))"
        fi
      } >"$tmp"
      chmod 0644 "$tmp"; mv "$tmp" "$textfile_dir/vault-restore-drill.prom"
      log "metrics written to $textfile_dir/vault-restore-drill.prom"
    else
      log "textfile directory not found; metrics not written"
    fi
  fi
  return "$failed"
}

# --- Backup -------------------------------------------------------------------
backup() { # dest_dir
  local dest="$1" ts out
  [[ -d "$dest" && -w "$dest" ]] || die "destination not a writable directory: $dest"
  vault token lookup >/dev/null 2>&1 || die "no valid production Vault token: vault login -method=userpass username=$login_user"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"; out="$dest/kif-vault-$ts.snap.gpg"
  plain="$(mktemp -p /dev/shm kif-vault-snap.XXXXXX)"
  log "saving Raft snapshot from ${VAULT_ADDR:-<unset VAULT_ADDR>} (plaintext in RAM only)"
  vault operator raft snapshot save "$plain"
  log "encrypting (gpg AES256; choose a passphrase and store it in KeePassXC)"
  gpg --quiet --no-symkey-cache --symmetric --cipher-algo AES256 --output "$out" "$plain"
  shred -u "$plain"; plain=""
  (cd "$dest" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")
  log "wrote $out ($(stat -c %s "$out") bytes) and .sha256"
}

# --- Self-test: same restore path, throwaway source, dummy data ---------------
self_test() {
  local key root keys pass pf name f
  selftest=1
  log "self-test: throwaway source Vault with dummy data"
  start_isolated "$src_ct" selftest-src-01
  keys="$(docker exec "$src_ct" vault operator init -key-shares=5 -key-threshold=3 -format=json)"
  mapfile -t unseal_keys < <(jq -r '.unseal_keys_b64[0:3][]' <<<"$keys")
  root="$(jq -r .root_token <<<"$keys")"; unset keys
  for key in "${unseal_keys[@]}"; do docker exec "$src_ct" vault operator unseal "$key" >/dev/null; done
  wait_active "$src_ct" "$root"
  s() { docker exec -i -e VAULT_TOKEN="$root" "$src_ct" vault "$@" >/dev/null; }
  s secrets enable -path=secret kv-v2
  s kv put "$canary" value=dummy
  s audit enable file file_path=/var/log/vault/audit.log
  for f in "$repo"/vault/policies/*.hcl; do
    name="$(basename "$f" .hcl)"; s policy write "$name" - <"$f"
  done
  s policy write drill-reader - <<'EOF'
path "sys/auth" { capabilities = ["read"] }
path "sys/policy/*" { capabilities = ["read"] }
path "sys/policies/acl/*" { capabilities = ["read"] }
path "sys/audit" { capabilities = ["read", "sudo"] }
path "sys/leader" { capabilities = ["read"] }
path "auth/kubernetes/role/*" { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["list"] }
EOF
  s auth enable kubernetes
  s write auth/kubernetes/config kubernetes_host=https://10.97.3.100:6443 disable_local_ca_jwt=true
  s write auth/kubernetes/role/prod-debug bound_service_account_names=prod-debug-sa \
    bound_service_account_namespaces=debug-system policies=production-debug-secrets ttl=15m max_ttl=1h
  login_password="$(head -c 18 /dev/urandom | base64)"
  s auth enable userpass
  s write "auth/userpass/users/$login_user" password="$login_password" policies=drill-reader
  docker exec -e VAULT_TOKEN="$root" "$src_ct" vault operator raft snapshot save /tmp/src.snap
  dir="$(mktemp -d -p /dev/shm kif-vault-selftest.XXXXXX)"
  plain="$dir/src.snap"; docker exec "$src_ct" cat /tmp/src.snap >"$plain"
  docker rm -f "$src_ct" >/dev/null
  pass="$(head -c 24 /dev/urandom | base64)"
  pf="$dir/pass"; printf '%s' "$pass" >"$pf"
  gpg --batch --quiet --passphrase-file "$pf" --symmetric --cipher-algo AES256 --output "$dir/src.snap.gpg" "$plain"
  shred -u "$plain"; plain=""
  (cd "$dir" && sha256sum src.snap.gpg > src.snap.gpg.sha256)
  exec {passphrase_fd}<"$pf"
  restore_drill "$dir/src.snap.gpg"   # trap shreds $dir
}

case "${1:-}" in
  backup)    [[ $# -eq 2 ]] || die "usage: $0 backup DEST_DIR"; backup "$2" ;;
  restore)   [[ $# -eq 2 ]] || die "usage: $0 restore FILE.gpg"; [[ -t 0 ]] || die "restore needs a terminal (passphrase, unseal shares, login)"; restore_drill "$2" ;;
  self-test) self_test ;;
  *) die "usage: $0 backup DEST_DIR | restore FILE.gpg | self-test" ;;
esac
