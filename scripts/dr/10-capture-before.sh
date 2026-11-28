#!/usr/bin/env bash
# DR phase 0b: record the "before" state (DR plan phase 0). Read-only.
#
#   scripts/dr/10-capture-before.sh
#
# Writes before.json (identities, objects, access model, Vault, monitoring),
# plus what the rebuild needs and cannot read once the VMs are gone: the
# load balancer definitions and the Ubuntu image from Terraform.
# shellcheck source=scripts/dr/lib.sh
. "$(dirname "$0")/lib.sh"
# Read-only phase: it always runs, so it is always timed as a real phase.
EXECUTE=1

RUN="$(dr_run_dir)"
dr_require_context
dr_phase 0-before start
python3 "$KIF_REPO/scripts/dr/capture-state.py" "$RUN/before.json"
terraform -chdir="$KIF_REPO/terraform" output -json load_balancers >"$RUN/load-balancers.json"
terraform -chdir="$KIF_REPO/terraform" console <<<'var.ubuntu_image' | tr -d '"' >"$RUN/ubuntu-image"
cp "$INVENTORY" "$RUN/hosts.before.yml"
chmod 600 "$RUN"/*
dr_phase 0-before end
python3 - "$RUN/before.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print(f"cluster CA fingerprint (pass to 17-restore-control-plane.yml): {s['identity']['cluster_ca_pubkey_sha256']}")
PY
echo "Load balancers recorded: $(python3 -c 'import json,sys; print(", ".join(v["name"] for v in json.load(open(sys.argv[1])).values()))' "$RUN/load-balancers.json")"
