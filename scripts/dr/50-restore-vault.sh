#!/usr/bin/env bash
# File-wide: the backup file names are fixed, so ls is fine.
# shellcheck disable=SC2012
# DR phase 4: Vault (DR plan phase 4). OPERATOR PRESENT: sudo, the USB
# backup passphrase, the KIF DR backup gpg passphrase, 3 of 5 unseal shares.
#
#   scripts/dr/50-restore-vault.sh [--execute]
#
# Same sequence as the restore drill (scripts/drills/vault-restore-drill.sh):
# rebuild the host service from the repository with the TLS files from the
# USB host-PKI archive, initialise a throwaway barrier, restore the snapshot
# with -force, then unseal with the real shares.
# shellcheck source=scripts/dr/lib.sh
. "$(dirname "$0")/lib.sh"

DR_USB="${DR_USB:-/media/robert/2565c03e-a345-47ed-9401-8c5477842293}"
export VAULT_ADDR="${VAULT_ADDR:-https://vault.kif.io:8200}"
export VAULT_CACERT="${VAULT_CACERT:-/usr/local/share/ca-certificates/kif-internal-root-ca.crt}"
SHM=/dev/shm/kif-dr
SNAP="$(ls -t "$DR_USB"/kif-vault/kif-vault-*.snap.gpg 2>/dev/null | head -1)"
HOST_PKI="$(ls -t "$DR_USB"/kif-dr/kif-host-pki-*.tar.gpg 2>/dev/null | head -1)"
[ -n "$SNAP" ] || dr_die "no Vault backup on $DR_USB"
[ -n "$HOST_PKI" ] || dr_die "no host PKI archive on $DR_USB"

dr_phase 4-vault start
dr_run install -d -m 0700 "$SHM/host-pki"
dr_run bash -c "gpg --decrypt '$HOST_PKI' | tar -C '$SHM/host-pki' -xf - opt/vault/tls"
dr_playbook 16-vault-server.yml --ask-become-pass -e "vault_tls_source_dir=$SHM/host-pki/opt/vault/tls"
dr_run rm -rf "$SHM/host-pki"

# A throwaway barrier: its one key and root token live in memory only.
dr_run bash -c "vault operator init -key-shares=1 -key-threshold=1 -format=json >'$SHM/temp-init.json'"
dr_run bash -c "vault operator unseal \"\$(python3 -c 'import json; print(json.load(open(\"$SHM/temp-init.json\"))[\"unseal_keys_b64\"][0])')\" >/dev/null"
dr_run bash -c "gpg --decrypt '$SNAP' >'$SHM/vault.snap'"
dr_run bash -c "VAULT_TOKEN=\"\$(python3 -c 'import json; print(json.load(open(\"$SHM/temp-init.json\"))[\"root_token\"])')\" vault operator raft snapshot restore -force '$SHM/vault.snap'"
dr_run shred -u "$SHM/vault.snap" "$SHM/temp-init.json"

echo "Vault now holds the restored data and is sealed with the REAL keys."
echo "Enter 3 of the 5 unseal shares (one per prompt):"
for _ in 1 2 3; do dr_run vault operator unseal; done
dr_run vault status
dr_phase 4-vault end
