#!/usr/bin/env bash
# DR phase 1: destroy (DR plan phase 1). POINT OF NO RETURN.
#
#   scripts/dr/20-destroy.sh             # dry run: print what would be destroyed
#   scripts/dr/20-destroy.sh --execute   # asks for a typed confirmation
#
# Deletes the five Kubernetes VMs (Terraform) and the two load balancers
# (not in the Terraform lifecycle, DR plan T7), stops Vault and moves its
# data, TLS files and configuration aside (kept until phase 6, never deleted
# here). Needs sudo for Vault.
# shellcheck source=scripts/dr/lib.sh
. "$(dirname "$0")/lib.sh"

RUN="$(dr_run_dir)"
for f in preflight.md before.json load-balancers.json ubuntu-image; do
    [ -s "$RUN/$f" ] || dr_die "missing $RUN/$f: run 00-preflight.sh and 10-capture-before.sh first"
done
if ! grep -q "^GO:" "$RUN/preflight.md"; then
    [ "$EXECUTE" -eq 1 ] && dr_die "the preflight for this run was not GO; refusing"
    echo "NOTE: the preflight was not GO; this dry run is a preview only."
fi
LBS="$(python3 -c 'import json,sys; print(" ".join(v["name"] for v in json.load(open(sys.argv[1])).values()))' "$RUN/load-balancers.json")"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

dr_confirm "destroy the kif platform"
dr_phase 1-destroy start
dr_run terraform -chdir="$KIF_REPO/terraform" destroy -auto-approve
for lb in $LBS; do
    dr_run multipass stop "$lb"
    dr_run multipass delete --purge "$lb"
done
# Vault loses its data, its TLS files and its configuration, so phase 4 must
# bring all three back from the repository and the USB disk (T5, T6). They
# are moved aside, never deleted, until phase 6.
dr_run sudo systemctl stop vault
dr_run sudo mv /opt/vault/data "/opt/vault/data.dr-$STAMP"
dr_run sudo mv /opt/vault/tls "/opt/vault/tls.dr-$STAMP"
dr_run sudo mv /etc/vault.d/vault.hcl "/etc/vault.d/vault.hcl.dr-$STAMP"
echo "$STAMP" >"$RUN/destroy-stamp"
dr_phase 1-destroy end
