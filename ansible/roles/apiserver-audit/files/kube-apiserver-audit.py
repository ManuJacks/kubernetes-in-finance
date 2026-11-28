#!/usr/bin/env python3
"""Add or remove API audit logging in a kubeadm kube-apiserver static pod manifest.

Usage: kube-apiserver-audit.py MANIFEST present|absent POLICY_DIR LOG_DIR \
           POLICY_SHA256 MAXAGE MAXBACKUP MAXSIZE

Idempotent. Prints "changed" or "unchanged". The policy checksum is written
as a pod annotation, so editing the policy alone also makes the kubelet
recreate the API server (it reads the policy only at startup).
Writes the new manifest atomically; the caller keeps a backup.
"""
import os
import sys
import tempfile

import yaml

FLAG_PREFIXES = ("--audit-policy-file=", "--audit-log-")
VOLUMES = ("audit-policy", "audit-log")
ANNOTATION = "kif.io/audit-policy-sha256"


def main(argv):
    manifest, state, policy_dir, log_dir, sha, maxage, maxbackup, maxsize = argv[1:]
    if state not in ("present", "absent"):
        raise SystemExit(f"state must be present or absent, not {state!r}")
    with open(manifest, encoding="utf-8") as fh:
        original = fh.read()
    pod = yaml.safe_load(original)

    spec = pod["spec"]
    (container,) = [c for c in spec["containers"] if c["name"] == "kube-apiserver"]
    command = [a for a in container["command"] if not a.startswith(FLAG_PREFIXES)]
    mounts = [m for m in container.get("volumeMounts", []) if m["name"] not in VOLUMES]
    volumes = [v for v in spec.get("volumes", []) if v["name"] not in VOLUMES]
    annotations = dict(pod["metadata"].get("annotations") or {})
    annotations.pop(ANNOTATION, None)

    if state == "present":
        command += [
            f"--audit-policy-file={policy_dir}/policy.yaml",
            f"--audit-log-path={log_dir}/audit.log",
            f"--audit-log-maxage={maxage}",
            f"--audit-log-maxbackup={maxbackup}",
            f"--audit-log-maxsize={maxsize}",
        ]
        mounts += [
            {"name": "audit-policy", "mountPath": policy_dir, "readOnly": True},
            {"name": "audit-log", "mountPath": log_dir, "readOnly": False},
        ]
        volumes += [
            {"name": "audit-policy", "hostPath": {"path": policy_dir, "type": "Directory"}},
            {"name": "audit-log", "hostPath": {"path": log_dir, "type": "DirectoryOrCreate"}},
        ]
        annotations[ANNOTATION] = sha

    container["command"] = command
    container["volumeMounts"] = mounts
    spec["volumes"] = volumes
    if annotations:
        pod["metadata"]["annotations"] = annotations
    else:
        pod["metadata"].pop("annotations", None)

    updated = yaml.safe_dump(pod, default_flow_style=False, sort_keys=False)
    if yaml.safe_load(updated) == yaml.safe_load(original):
        print("unchanged")
        return
    # The kubelet runs every file in the manifests directory, so the temp file
    # goes in its parent (same filesystem) and is renamed into place.
    parent = os.path.dirname(os.path.dirname(os.path.abspath(manifest)))
    fd, tmp = tempfile.mkstemp(dir=parent, prefix=".kube-apiserver-audit-")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(updated)
    os.chmod(tmp, 0o600)
    os.replace(tmp, manifest)
    print("changed")


if __name__ == "__main__":
    main(sys.argv)
