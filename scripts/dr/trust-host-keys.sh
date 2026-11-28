#!/usr/bin/env bash
# Pin the SSH host keys of rebuilt VMs (DR plan T17).
#
#   scripts/dr/trust-host-keys.sh <old-inventory.yml>
#
# Ansible checks host keys (host_key_checking = True), and a rebuilt VM has a
# new one, so every connection would fail with "REMOTE HOST IDENTIFICATION
# HAS CHANGED". Instead of switching checking off or trusting the first key
# offered, read each VM's ed25519 host key over `multipass exec` (a channel
# that does not go through SSH) and pin it in ~/.ssh/known_hosts. Old entries
# for both the old and the new address are removed first.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OLD="${1:?usage: $0 <old-inventory.yml>}"
KNOWN="${KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"

pairs() { # name address, from an inventory file
    awk '/^ *[A-Za-z0-9._-]+:$/ {n=$1; sub(":", "", n)} /ansible_host:/ {print n, $2}' "$1"
}

while read -r name old_ip; do
    new_ip="$(pairs "$REPO/ansible/inventory/hosts.yml" | awk -v n="$name" '$1==n {print $2}')"
    [ -n "$new_ip" ] || { echo "no new address for $name" >&2; exit 1; }
    key="$(multipass exec "$name" -- cat /etc/ssh/ssh_host_ed25519_key.pub </dev/null | awk '{print $1, $2}')"
    [[ "$key" == ssh-ed25519\ * ]] || { echo "could not read the host key of $name" >&2; exit 1; }
    # multipass exec reads stdin: without </dev/null it swallows the rest of this loop.
    ssh-keygen -R "$old_ip" -f "$KNOWN" >/dev/null 2>&1 || true
    ssh-keygen -R "$new_ip" -f "$KNOWN" >/dev/null 2>&1 || true
    echo "$new_ip $key" >>"$KNOWN"
    echo "pinned $name ($new_ip) $(ssh-keygen -lf <(echo "$new_ip $key") | awk '{print $2}')"
done < <(pairs "$OLD")
ssh-keygen -H -f "$KNOWN" >/dev/null 2>&1 && rm -f "$KNOWN.old"
