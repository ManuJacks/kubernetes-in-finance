#!/usr/bin/env python3
"""Print redacted Vault audit entries for the 2026-11-28T00:15Z smoke test.

Keeps only time, type, path, operation, identity name, policies, remote
address and error. Drops every HMAC'd field, token, accessor and client token.
Usage: sudo python3 -I scripts/vault-audit-extract.py /var/log/vault/audit.log
"""
import json
import sys

SINCE = "2026-11-28T00:14"
PATHS = ("auth/kubernetes/login", "secret/data/production-debug/")

with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("time", "") < SINCE:
            continue
        req = e.get("request") or {}
        path = req.get("path", "")
        if not path.startswith(PATHS):
            continue
        auth = e.get("auth") or {}
        meta = auth.get("metadata") or {}
        print(json.dumps({
            "time": e.get("time"),
            "type": e.get("type"),
            "path": path,
            "operation": req.get("operation"),
            "remote_address": req.get("remote_address"),
            "display_name": auth.get("display_name"),
            "policies": auth.get("policies"),
            "sa": "/".join(filter(None, (meta.get("service_account_namespace"),
                                         meta.get("service_account_name")))) or None,
            "error": e.get("error") or None,
        }))
