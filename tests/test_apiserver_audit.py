"""Static guards for Kubernetes API audit logging (CHG-2026-11-27)."""

import os
import subprocess
import sys

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ROLE = os.path.join(ROOT, "ansible", "roles", "apiserver-audit")
SCRIPT = os.path.join(ROLE, "files", "kube-apiserver-audit.py")

MANIFEST = """\
apiVersion: v1
kind: Pod
metadata:
  annotations:
    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: 10.0.0.1:6443
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    - --secure-port=6443
    name: kube-apiserver
    volumeMounts:
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
  volumes:
  - hostPath:
      path: /etc/kubernetes/pki
      type: DirectoryOrCreate
    name: k8s-certs
"""


def policy():
    with open(os.path.join(ROLE, "files", "audit-policy.yaml")) as f:
        return yaml.safe_load(f)


def first_rule_for(resource, group=""):
    for rule in policy()["rules"]:
        for res in rule.get("resources", []):
            if res.get("group", "") == group and (
                "resources" not in res or resource in res["resources"]
            ):
                return rule
    raise AssertionError(f"no rule matches {group}/{resource}")


def test_secrets_and_tokens_never_have_bodies_recorded():
    for resource, group in (
        ("secrets", ""),
        ("configmaps", ""),
        ("serviceaccounts/token", ""),
        ("tokenreviews", "authentication.k8s.io"),
    ):
        assert first_rule_for(resource, group)["level"] in ("None", "Metadata"), resource


def test_access_changes_are_recorded_in_full():
    assert first_rule_for("rolebindings", "rbac.authorization.k8s.io")["level"] == "RequestResponse"
    assert (
        first_rule_for("validatingadmissionpolicies", "admissionregistration.k8s.io")["level"]
        == "RequestResponse"
    )


def test_diagnostic_identity_is_recorded():
    users = [u for r in policy()["rules"] if r["level"] != "None" for u in r.get("users", [])]
    assert "system:serviceaccount:debug-system:prod-debug-sa" in users


def test_policy_ends_with_a_catch_all():
    last = policy()["rules"][-1]
    assert last == {"level": "None"}


def run(path, state):
    return subprocess.run(
        [sys.executable, SCRIPT, path, state, "/etc/kubernetes/audit",
         "/var/log/kubernetes/audit", "abc123", "7", "4", "50"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()


def test_manifest_patch_is_idempotent_and_reversible(tmp_path):
    manifests = tmp_path / "manifests"
    manifests.mkdir()
    path = manifests / "kube-apiserver.yaml"
    path.write_text(MANIFEST)

    assert run(str(path), "present") == "changed"
    pod = yaml.safe_load(path.read_text())
    command = pod["spec"]["containers"][0]["command"]
    assert "--audit-policy-file=/etc/kubernetes/audit/policy.yaml" in command
    assert "--audit-log-maxsize=50" in command
    assert pod["metadata"]["annotations"]["kif.io/audit-policy-sha256"] == "abc123"
    assert run(str(path), "present") == "unchanged"
    # Nothing but the manifest may be left in the kubelet's directory.
    assert [p.name for p in manifests.iterdir()] == ["kube-apiserver.yaml"]

    assert run(str(path), "absent") == "changed"
    assert yaml.safe_load(path.read_text()) == yaml.safe_load(MANIFEST)


def test_playbook_changes_one_control_plane_at_a_time():
    with open(os.path.join(ROOT, "ansible", "playbooks", "15-apiserver-audit.yml")) as f:
        plays = yaml.safe_load(f)
    apply = [p for p in plays if "apiserver-audit" in p.get("roles", [])]
    assert len(apply) == 1
    assert apply[0]["serial"] == 1
    assert apply[0]["any_errors_fatal"] is True


def test_backups_are_outside_the_manifests_directory():
    with open(os.path.join(ROLE, "defaults", "main.yml")) as f:
        defaults = yaml.safe_load(f)
    assert not defaults["apiserver_audit_backup_dir"].startswith("/etc/kubernetes/manifests")
