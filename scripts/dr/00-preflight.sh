#!/usr/bin/env bash
# File-wide: check functions are called through check(); the listed file
# names are fixed, so ls is fine.
# shellcheck disable=SC2329,SC2012
# DR phase 0a: go/no-go (DR plan section 4). Read-only; starts a new run
# directory for the exercise's evidence.
#
#   scripts/dr/00-preflight.sh
#
# Prints PASS / FAIL / MANUAL per check and exits 0 only when every automated
# check passes. MANUAL items are for the operator to confirm aloud.
# Settings (environment):
#   DR_USB                 USB backup disk mount point
#   DR_VAULT_LAST_CHANGE   last Vault change (UTC); the Vault backup must be newer
#   DR_MAX_BACKUP_AGE_MIN  etcd snapshot and PKI archive maximum age (60)
# shellcheck source=scripts/dr/lib.sh
. "$(dirname "$0")/lib.sh"

DR_USB="${DR_USB:-/media/robert/2565c03e-a345-47ed-9401-8c5477842293}"
DR_VAULT_LAST_CHANGE="${DR_VAULT_LAST_CHANGE:-2026-11-28T00:15:02Z}"
DR_MAX_BACKUP_AGE_MIN="${DR_MAX_BACKUP_AGE_MIN:-60}"
DR_KEY_FPR="838E3C42CE171DDB66B132113A4B349DEC36404A"
export VAULT_ADDR="${VAULT_ADDR:-https://vault.kif.io:8200}"
export VAULT_CACERT="${VAULT_CACERT:-/usr/local/share/ca-certificates/kif-internal-root-ca.crt}"

RUN_DIR="$(dr_new_run)"
export DR_RUN_DIR="$RUN_DIR"
REPORT="$RUN_DIR/preflight.md"
failed=0

check() { # <name> <command...>: PASS when the command succeeds
    local name="$1" out
    shift
    if out="$("$@" 2>&1)"; then
        printf '| PASS | %s | %s |\n' "$name" "${out//$'\n'/; }" | tee -a "$REPORT"
    else
        printf '| FAIL | %s | %s |\n' "$name" "${out//$'\n'/; }" | tee -a "$REPORT"
        failed=1
    fi
}
manual() { printf '| MANUAL | %s | operator confirms |\n' "$1" | tee -a "$REPORT"; }

# --- checks: each prints one line of evidence and fails with a reason ----------
nodes_ready() {
    local ready total
    ready="$(kubectl get nodes --no-headers | awk '$2=="Ready"' | wc -l)"
    total="$(kubectl get nodes --no-headers | wc -l)"
    echo "$ready/$total Ready"
    [ "$ready" -eq 5 ] && [ "$total" -eq 5 ]
}

backup_ages() { # newest etcd snapshot and PKI archive per control plane
    local out
    # The remote script always exits 0 and reports OK/BAD, so the result is
    # one readable line per node instead of Ansible's failure JSON.
    # shellcheck disable=SC2016  # expands on the node, not here
    out="$(ansible -i "$INVENTORY" control_plane -b -o -m shell -a '
        now=$(date +%s); h=$(hostname -s); max='"$DR_MAX_BACKUP_AGE_MIN"'
        s=$(ls -t /var/backups/etcd/etcd-snapshot-$h-*.db 2>/dev/null | head -1)
        p=$(ls -t /var/backups/etcd/cluster-pki-$h-*.tar.gpg 2>/dev/null | head -1)
        sa=none; pa=none; ok=OK; m=m
        if [ -n "$s" ]; then sa=$(( (now - $(stat -c %Y "$s")) / 60 )); [ $sa -le $max ] || ok=BAD; else ok=BAD; fi
        if [ -n "$p" ]; then pa=$(( (now - $(stat -c %Y "$p")) / 60 )); [ $pa -le $max ] || ok=BAD; else ok=BAD; fi
        echo "$ok $h snapshot=${sa} pki=${pa}" | sed -E "s/=([0-9]+)/=\1min/g"' 2>&1 | grep -oE '(OK|BAD) [^ ]+ snapshot=[^ ]+ pki=[^ ]+' | sort)"
    echo "$out"
    [ "$(grep -c '^OK ' <<<"$out")" -eq 3 ]
}

vault_backup_fresh() {
    local f
    f="$(ls -t "$DR_USB"/kif-vault/kif-vault-*.snap.gpg 2>/dev/null | head -1)"
    [ -n "$f" ] || { echo "no Vault backup on $DR_USB"; return 1; }
    local taken changed
    taken="$(stat -c %Y "$f")"
    changed="$(date -d "$DR_VAULT_LAST_CHANGE" +%s)"
    echo "$(basename "$f") taken $(date -u -d "@$taken" +%FT%TZ); last Vault change $DR_VAULT_LAST_CHANGE"
    (cd "$(dirname "$f")" && sha256sum -c --quiet "$(basename "$f").sha256") || { echo "checksum mismatch"; return 1; }
    [ "$taken" -gt "$changed" ] || { echo "backup is OLDER than the last Vault change (T4)"; return 1; }
}

host_pki_archive() {
    local f
    f="$(ls -t "$DR_USB"/kif-dr/kif-host-pki-*.tar.gpg 2>/dev/null | head -1)"
    [ -n "$f" ] || { echo "no host PKI archive on $DR_USB"; return 1; }
    (cd "$(dirname "$f")" && sha256sum -c --quiet "$(basename "$f").sha256") && echo "$(basename "$f") checksum ok"
}

dr_key_offline() {
    gpg --show-keys --with-colons "$DR_USB/kif-dr/kif-dr-backup-secret.asc" 2>/dev/null \
        | grep -q "^fpr:::::::::$DR_KEY_FPR:" && echo "secret key for $DR_KEY_FPR on USB"
}

vault_unsealed() {
    vault status -format=json 2>/dev/null | python3 -c '
import json, sys
s = json.load(sys.stdin); print("sealed" if s["sealed"] else "unsealed", s.get("version"))
sys.exit(1 if s["sealed"] else 0)'
}

vault_24h_check_done() {
    if grep -q "^## 6\." "$KIF_REPO/docs/security/evidence/2026-11-27-vault-tokenreview-credential.md"; then
        echo "24-hour re-run recorded (evidence section 6)"
    else
        echo "24-hour Vault login re-run not recorded yet"
        return 1
    fi
}

clocks_in_sync() { # chrony's own offset on every VM (an SSH round trip would add latency)
    ansible -i "$INVENTORY" kubernetes:load_balancers -o -m shell \
        -a "chronyc -n tracking | awk '/^System time/ {print \$4}'" 2>/dev/null \
        | awk '{print $1, $NF}' | python3 -c '
import sys
rows = [l.split() for l in sys.stdin if l.strip()]
worst = max((abs(float(v)) for _, v in rows), default=None)
if worst is None or len(rows) < 7:
    print(f"chrony offset read from {len(rows)}/7 VMs"); sys.exit(1)
print(f"worst chrony offset {worst*1000:.1f} ms across {len(rows)} VMs")
sys.exit(0 if worst <= 0.5 else 1)'
}

inventory_matches_multipass() {
    python3 "$KIF_REPO/scripts/readdress.py" | tail -1
    python3 "$KIF_REPO/scripts/readdress.py" | grep -q "nothing to do"
}

# --- report ------------------------------------------------------------------
{
    echo "# DR preflight $(date -u +%FT%TZ)"
    echo
    echo "| Result | Check | Evidence |"
    echo "|---|---|---|"
} >"$REPORT"
dr_require_context
check "All five nodes Ready" nodes_ready
check "etcd snapshot and PKI archive per control plane, under ${DR_MAX_BACKUP_AGE_MIN} min (T1)" backup_ages
check "Vault backup on USB, checksum ok, newer than the last Vault change (T4)" vault_backup_fresh
check "Host PKI archive (KIF CA, Vault TLS) on USB, checksum ok (T6)" host_pki_archive
check "DR private key on USB (T13)" dr_key_offline
check "Vault unsealed" vault_unsealed
check "24-hour Vault login check recorded" vault_24h_check_done
check "VM clocks in sync (chrony offset under 500 ms)" clocks_in_sync
check "Inventory matches multipass (T2)" inventory_matches_multipass
manual "Operator present with 3 of 5 unseal shares, the gpg passphrase, sudo, about 3 hours"
manual "Nothing else running against the cluster (no other changes in flight)"

echo
if [ "$failed" -eq 0 ]; then
    echo "GO: every automated check passed. Confirm the MANUAL items, then run 10-capture-before.sh." | tee -a "$REPORT"
else
    echo "NO-GO: fix the FAIL items above. Nothing was changed." | tee -a "$REPORT"
fi
echo "Evidence: $RUN_DIR"
exit "$failed"
