#!/usr/bin/env python3
"""Print redacted Kubernetes API audit events about diagnostic access.

Keeps RoleBinding writes and every request by (or impersonating)
debug-system/prod-debug-sa. Output: time, level, user, impersonated user,
verb, resource, namespace, name, response code, roleRef name. No bodies.
Usage (on a control plane):
  sudo python3 -I k8s-audit-extract.py SINCE [LOG]
  SINCE is an RFC 3339 UTC time, compared to the second.
Note: the audit policy is evaluated before impersonation, so `kubectl --as`
reads are matched as the impersonator and are not recorded. Test the
identity rule with a real token (`kubectl create token`).
"""
import json
import sys

SA = "system:serviceaccount:debug-system:prod-debug-sa"
since = sys.argv[1][:19]
log = sys.argv[2] if len(sys.argv) > 2 else "/var/log/kubernetes/audit/audit.log"

with open(log, encoding="utf-8") as fh:
    for line in fh:
        e = json.loads(line)
        if e.get("stageTimestamp", "")[:19] < since:
            continue
        ref = e.get("objectRef") or {}
        user = e["user"]["username"]
        imp = (e.get("impersonatedUser") or {}).get("username")
        binding_write = ref.get("resource") == "rolebindings" and e["verb"] in (
            "create", "update", "patch", "delete")
        if not (binding_write or SA in (user, imp)):
            continue
        print(json.dumps({
            "time": e["stageTimestamp"],
            "level": e["level"],
            "user": user,
            "as": imp,
            "verb": e["verb"],
            "resource": ref.get("resource"),
            "ns": ref.get("namespace"),
            "name": ref.get("name"),
            "code": (e.get("responseStatus") or {}).get("code"),
            "roleRef": ((e.get("requestObject") or {}).get("roleRef") or {}).get("name"),
        }))
