#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 8 ]]; then
  echo "Usage: $0 create NAME ZONE CPUS MEMORY DISK IMAGE FRONTEND_IP" >&2
  exit 2
fi

ACTION="$1"
NAME="$2"
ZONE="$3"
CPUS="$4"
MEMORY="$5"
DISK="$6"
IMAGE="$7"
FRONTEND_IP="$8"

BRIDGE="br-api-frontend"
VIP="10.97.3.100"

if [[ "$ACTION" != "create" ]]; then
  echo "ERROR: Only the create action is supported." >&2
  exit 2
fi

if [[ ! "$NAME" =~ ^api-lb[0-9]+-[a-z0-9-]+$ ]]; then
  echo "ERROR: Invalid load balancer name: $NAME" >&2
  exit 1
fi

if [[ ! "$FRONTEND_IP" =~ ^10\.97\.3\.([0-9]{1,3})$ ]]; then
  echo "ERROR: Frontend IP must belong to 10.97.3.0/24." >&2
  exit 1
fi

LAST_OCTET=$((10#${BASH_REMATCH[1]}))

if (( LAST_OCTET < 1 || LAST_OCTET > 254 )); then
  echo "ERROR: Frontend IP cannot be a network or broadcast address." >&2
  exit 1
fi

case "$FRONTEND_IP" in
  10.97.3.11|10.97.3.12|"$VIP")
    echo "ERROR: Frontend IP $FRONTEND_IP is reserved." >&2
    exit 1
    ;;
esac

if [[ ! "$CPUS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: CPU count must be a positive integer." >&2
  exit 1
fi

command -v multipass >/dev/null 2>&1 || {
  echo "ERROR: multipass CLI not found." >&2
  exit 1
}

if multipass info "$NAME" >/dev/null 2>&1; then
  echo "ERROR: $NAME already exists. Refusing to overwrite it." >&2
  exit 1
fi

if ! multipass zones | awk 'NR > 1 {print $1}' | grep -Fxq "$ZONE"; then
  echo "ERROR: Multipass zone $ZONE is unavailable." >&2
  exit 1
fi

if ! multipass networks | awk 'NR > 1 {print $1}' | grep -Fxq "$BRIDGE"; then
  echo "ERROR: Frontend bridge $BRIDGE is unavailable." >&2
  exit 1
fi

# Refuse frontend addresses already reported by another Multipass VM.
if multipass list --format json | python3 -c '
import json
import sys

requested = sys.argv[1]
data = json.load(sys.stdin)

for vm in data.get("list", []):
    if requested in vm.get("ipv4", []):
        name = vm.get("name", "unknown")
        print(f"ERROR: {requested} is already assigned to VM {name}", file=sys.stderr)
        sys.exit(1)
' "$FRONTEND_IP"; then
  :
else
  echo "ERROR: Frontend IP collision check failed or address is already assigned." >&2
  exit 1
fi

echo "Creating $NAME in $ZONE"
echo "Management interface: DHCP"
echo "Frontend bridge: $BRIDGE"
echo "Frontend address: $FRONTEND_IP/24"

multipass launch \
  --name "$NAME" \
  --zone "$ZONE" \
  --cpus "$CPUS" \
  --memory "$MEMORY" \
  --disk "$DISK" \
  --network "name=$BRIDGE,mode=manual" \
  "$IMAGE"

if ! multipass exec "$NAME" -- ip link show dev eth1 >/dev/null 2>&1; then
  echo "ERROR: Expected frontend interface eth1 was not found." >&2
  echo "VM $NAME was left in place for investigation; it was not deleted." >&2
  exit 1
fi

echo "Configuring static frontend address on eth1"

multipass exec "$NAME" -- sudo tee \
  /etc/netplan/60-load-balancer-frontend.yaml >/dev/null <<NETPLAN
network:
  version: 2
  ethernets:
    eth1:
      dhcp4: false
      dhcp6: false
      optional: true
      addresses:
        - ${FRONTEND_IP}/24
NETPLAN

multipass exec "$NAME" -- sudo chmod 600 \
  /etc/netplan/60-load-balancer-frontend.yaml

multipass exec "$NAME" -- sudo netplan generate
multipass exec "$NAME" -- sudo netplan apply

if ! multipass exec "$NAME" -- \
  ip -4 -o addr show dev eth1 | grep -Fq "$FRONTEND_IP/24"; then
  echo "ERROR: Frontend address verification failed." >&2
  echo "VM $NAME was left in place for investigation; it was not deleted." >&2
  exit 1
fi

echo "Load balancer VM created and frontend address verified."
multipass info "$NAME"
