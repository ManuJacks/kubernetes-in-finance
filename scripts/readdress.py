#!/usr/bin/env python3
"""Re-address the repository after VMs are rebuilt (DR plan gap T2).

Multipass gives rebuilt VMs new DHCP addresses. This reads each VM's current
management address from `multipass list` and rewrites the old address, by node
name, everywhere current configuration hard-codes it. History (incidents, game
days, evidence, change records) is never rewritten.

    scripts/readdress.py            # dry run: print the map and a diff
    scripts/readdress.py --apply    # write the files

The old address of each node comes from ansible/inventory/hosts.yml
(ansible_host), the new one from multipass. Exits 0 when nothing changes or
the apply succeeds, 1 on a refused map, 2 on misuse.

After --apply: re-run the playbooks that render these files
(02-load-balancers.yml for HAProxy, 13-monitoring.yml for Prometheus); the
kubeadm template is used by 03-kubernetes-bootstrap.yml.
"""

from __future__ import annotations

import argparse
import difflib
import ipaddress
import json
import re
import subprocess
import sys
from pathlib import Path

# Current-state files only. Keep in sync with docs/dr/DR-PLAN-full-platform.md.
TARGETS = [
    "ansible/inventory/hosts.yml",
    "ansible/inventory/group_vars/load_balancers.yml",
    "ansible/roles/kubernetes-bootstrap/templates/kubeadm-init.yaml.j2",
    "monitoring/prometheus/prometheus.yml",
    "terraform/main.tf",
    "docs/architecture/overview.md",
    "docs/runbooks/network-connectivity.md",
    "docs/runbooks/multipassd-crash.md",
]
# Management networks, one /24 per Multipass zone. 10.97.3.0/24 (frontend and
# the API VIP) is static and never re-addressed; 10.244.0.0/16 is pod space.
MANAGEMENT = ipaddress.ip_network("10.97.0.0/22")
STATIC = ipaddress.ip_network("10.97.3.0/24")

HOST_RE = re.compile(r"^(\s*)([\w.-]+):\s*$")
ANSIBLE_HOST_RE = re.compile(r"^\s*ansible_host:\s*([\d.]+)\s*$")


def old_addresses(inventory: Path) -> dict[str, str]:
    """name -> ansible_host, read without a YAML library (stdlib only)."""
    result, current = {}, None
    for line in inventory.read_text().splitlines():
        m = ANSIBLE_HOST_RE.match(line)
        if m and current:
            result[current] = m.group(1)
            continue
        m = HOST_RE.match(line)
        if m:
            current = m.group(2)
    return result


def new_addresses(listing: dict) -> dict[str, str]:
    result = {}
    for vm in listing["list"]:
        for addr in vm.get("ipv4", []):
            ip = ipaddress.ip_address(addr)
            if ip in MANAGEMENT and ip not in STATIC:
                result[vm["name"]] = addr
                break
    return result


def build_map(old: dict[str, str], new: dict[str, str]) -> tuple[dict[str, str], list[str]]:
    errors, mapping = [], {}
    for name, old_ip in sorted(old.items()):
        if name not in new:
            errors.append(f"{name}: no running VM with a management address in multipass")
            continue
        new_ip = new[name]
        if ipaddress.ip_network(f"{old_ip}/24", strict=False) != ipaddress.ip_network(
            f"{new_ip}/24", strict=False
        ):
            errors.append(f"{name}: {old_ip} -> {new_ip} changes zone subnet; refusing")
        if old_ip != new_ip:
            mapping[old_ip] = new_ip
    targets = [new[n] for n in old if n in new]
    dupes = {ip for ip in targets if targets.count(ip) > 1}
    if dupes:
        errors.append(f"duplicate new addresses: {sorted(dupes)}")
    return mapping, errors


def rewrite(text: str, mapping: dict[str, str]) -> str:
    """Replace whole addresses only, in two phases so swaps are safe."""
    tokens = {old: f"\0READDRESS{i}\0" for i, old in enumerate(mapping)}
    for old, token in tokens.items():
        text = re.sub(rf"(?<![\d.]){re.escape(old)}(?![\d.]*\d)", token, text)
    for old, token in tokens.items():
        text = text.replace(token, mapping[old])
    return text


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true", help="write the files")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--multipass-json", type=Path, help="read the listing from a file (tests)")
    args = parser.parse_args(argv)

    if args.multipass_json:
        listing = json.loads(args.multipass_json.read_text())
    else:
        out = subprocess.run(
            ["multipass", "list", "--format", "json"], capture_output=True, text=True, check=True
        ).stdout
        listing = json.loads(out)

    old = old_addresses(args.root / "ansible/inventory/hosts.yml")
    if not old:
        print("no ansible_host entries found in the inventory", file=sys.stderr)
        return 2
    mapping, errors = build_map(old, new_addresses(listing))
    for e in errors:
        print(f"refused: {e}", file=sys.stderr)
    if errors:
        return 1

    names = {v: k for k, v in old.items()}
    for old_ip, new_ip in sorted(mapping.items()):
        print(f"{names[old_ip]:<16} {old_ip:<15} -> {new_ip}")
    if not mapping:
        print("addresses unchanged; nothing to do")
        return 0

    changed = 0
    for rel in TARGETS:
        path = args.root / rel
        if not path.exists():
            continue
        before = path.read_text()
        after = rewrite(before, mapping)
        if after == before:
            continue
        changed += 1
        sys.stdout.writelines(
            difflib.unified_diff(
                before.splitlines(True), after.splitlines(True), f"a/{rel}", f"b/{rel}", n=0
            )
        )
        if args.apply:
            path.write_text(after)
    verb = "rewrote" if args.apply else "would rewrite"
    print(f"{verb} {changed} file(s)")
    if not args.apply:
        print("dry run; re-run with --apply to write")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
