#!/usr/bin/env python3
"""Capture the platform's state as one JSON document (DR phases 0 and 5).

Read-only. The same collector runs before the DR (before.json) and after it
(after.json), and 60-verify.sh compares the two, so "recovered" means
"the same as before", not "looks fine".

    scripts/dr/capture-state.py <out.json>

Records identities (cluster CA and service-account key fingerprints), object
names and counts per kind, the access-model objects, and Vault and
monitoring status. Never records Secret contents, only names and counts.
"""

from __future__ import annotations

import base64
import datetime as dt
import hashlib
import json
import os
import subprocess
import sys

KINDS = [
    "namespaces", "deployments", "statefulsets", "daemonsets", "services",
    "configmaps", "secrets", "serviceaccounts", "roles", "rolebindings",
    "clusterroles", "clusterrolebindings", "validatingadmissionpolicies",
    "validatingadmissionpolicybindings", "cronjobs", "customresourcedefinitions",
    "persistentvolumeclaims", "networkpolicies",
]
os.environ.setdefault("KUBECONFIG", os.path.expanduser("~/.kube/kubernetes-in-finance.conf"))


def sh(*cmd: str, check: bool = True) -> str:
    return subprocess.run(cmd, capture_output=True, text=True, check=check).stdout


def kjson(*args: str) -> dict:
    return json.loads(sh("kubectl", *args, "-o", "json"))


def der_sha256_of_cert_pem(pem: bytes) -> str:
    pub = subprocess.run(["openssl", "x509", "-noout", "-pubkey"], input=pem, capture_output=True, check=True).stdout
    der = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"], input=pub, capture_output=True, check=True).stdout
    return hashlib.sha256(der).hexdigest()


def cluster_ca_fingerprint() -> str:
    cfg = json.loads(sh("kubectl", "config", "view", "--raw", "--minify", "-o", "json"))
    pem = base64.b64decode(cfg["clusters"][0]["cluster"]["certificate-authority-data"])
    return der_sha256_of_cert_pem(pem)


def sa_key_fingerprint(repo: str) -> str | None:
    env = {**os.environ, "ANSIBLE_CONFIG": os.path.join(repo, "ansible/ansible.cfg")}
    out = subprocess.run(
        ["ansible", "-i", os.path.join(repo, "ansible/inventory/hosts.yml"), "tf-ha-control1", "-b", "-o",
         "-m", "shell", "-a", "sha256sum /etc/kubernetes/pki/sa.pub | cut -d' ' -f1"],
        capture_output=True, text=True, env=env,
    ).stdout
    words = out.split()
    return words[-1] if words and len(words[-1]) == 64 else None


def objects() -> dict:
    result = {}
    for kind in KINDS:
        items = kjson("get", kind, "-A").get("items", [])
        names = sorted(
            f"{i['metadata'].get('namespace', '')}/{i['metadata']['name']}".lstrip("/")
            for i in items
        )
        result[kind] = {"count": len(names), "names": names if kind != "secrets" else None}
    return result


def access_model() -> dict:
    rbs = kjson("get", "rolebindings", "-A")["items"]
    grants = sorted(
        f"{r['metadata']['namespace']}/{r['metadata']['name']}"
        for r in rbs if r["roleRef"]["name"] in ("prod-debug-reader", "prod-debug-log-reader")
    )
    vap = kjson("get", "validatingadmissionpolicy", "production-debug-access-guard")
    reaper = subprocess.run(["kubectl", "-n", "debug-system", "get", "cronjob", "prod-debug-grant-reaper"],
                            capture_output=True).returncode == 0
    labelled = sorted(
        n["metadata"]["name"] for n in kjson("get", "namespaces")["items"]
        if n["metadata"].get("labels", {}).get("production-debug/diagnosable") == "true"
    )
    return {
        "debug_grants": grants,
        "access_guard_rules": len(vap["spec"]["validations"]),
        "grant_reaper_cronjob": reaper,
        "diagnosable_namespaces": labelled,
    }


def vault() -> dict:
    env = {**os.environ,
           "VAULT_ADDR": os.environ.get("VAULT_ADDR", "https://vault.kif.io:8200"),
           "VAULT_CACERT": os.environ.get("VAULT_CACERT", "/usr/local/share/ca-certificates/kif-internal-root-ca.crt")}
    out = subprocess.run(["vault", "status", "-format=json"], capture_output=True, text=True, env=env).stdout
    try:
        s = json.loads(out)
        return {"sealed": s["sealed"], "version": s.get("version"), "initialized": s.get("initialized")}
    except ValueError:
        return {"reachable": False}


def monitoring() -> dict:
    try:
        out = sh("curl", "-s", "http://127.0.0.1:9090/api/v1/targets?state=active")
        targets = json.loads(out)["data"]["activeTargets"]
        return {"targets": len(targets), "up": sum(t["health"] == "up" for t in targets)}
    except Exception as exc:  # monitoring down is a finding, not a crash
        return {"error": str(exc)}


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    repo = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    nodes = kjson("get", "nodes")["items"]
    state = {
        "captured_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "identity": {
            "cluster_ca_pubkey_sha256": cluster_ca_fingerprint(),
            "sa_pub_sha256": sa_key_fingerprint(repo),
        },
        "nodes": sorted(
            ({"name": n["metadata"]["name"],
              "ready": any(c["type"] == "Ready" and c["status"] == "True" for c in n["status"]["conditions"])}
             for n in nodes),
            key=lambda n: n["name"],
        ),
        "objects": objects(),
        "access_model": access_model(),
        "vault": vault(),
        "monitoring": monitoring(),
    }
    with open(sys.argv[1], "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)
    print(f"captured {sum(v['count'] for v in state['objects'].values())} objects across "
          f"{len(KINDS)} kinds, {len(state['nodes'])} nodes -> {sys.argv[1]}")
    print(f"cluster CA public-key SHA-256: {state['identity']['cluster_ca_pubkey_sha256']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
