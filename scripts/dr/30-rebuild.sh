#!/usr/bin/env bash
# DR phase 2: rebuild the VMs and re-address (DR plan phase 2).
#
#   scripts/dr/30-rebuild.sh [--execute]
#
# Recreates the five Kubernetes VMs (Terraform) and the two load balancers
# with their recorded addresses (LB_REBUILD=1, DR plan T15), re-addresses the
# repository from multipass (T2), pins each new VM's SSH host key read over
# multipass exec rather than trusting it on first use (T17), then runs the
# base playbooks.
# shellcheck source=scripts/dr/lib.sh
. "$(dirname "$0")/lib.sh"

RUN="$(dr_run_dir)"
IMAGE="$(cat "$RUN/ubuntu-image")"

dr_phase 2-rebuild start
dr_run terraform -chdir="$KIF_REPO/terraform" apply -auto-approve
while read -r name zone cpus mem disk fip; do
    dr_run env LB_REBUILD=1 "$KIF_REPO/scripts/multipass-load-balancer.sh" \
        create "$name" "$zone" "$cpus" "$mem" "$disk" "$IMAGE" "$fip"
done < <(python3 -c '
import json, sys
for lb in json.load(open(sys.argv[1])).values():
    print(lb["name"], lb["zone"], lb["cpus"], lb["memory_bytes"], lb["disk_bytes"], lb["frontend_ip"])' \
    "$RUN/load-balancers.json")

dr_run python3 "$KIF_REPO/scripts/readdress.py" --apply
dr_run "$KIF_REPO/scripts/dr/trust-host-keys.sh" "$RUN/hosts.before.yml"
dr_run ansible -i "$INVENTORY" all -m ansible.builtin.wait_for_connection -a timeout=300
dr_playbook 01-common.yml
dr_playbook 02-load-balancers.yml
dr_playbook 11-time-sync.yml
dr_phase 2-rebuild end
