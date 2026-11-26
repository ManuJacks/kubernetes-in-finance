"""Tenant namespaces must enforce Pod Security restricted and run compliant workloads."""

import glob
import os

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TENANT_FILES = sorted(glob.glob(os.path.join(ROOT, "kubernetes", "tenants", "app-team-*.yaml")))


def docs(path):
    with open(path) as fh:
        return [d for d in yaml.safe_load_all(fh) if d]


def test_tenants_exist():
    names = [os.path.basename(p) for p in TENANT_FILES]
    assert names == ["app-team-a.yaml", "app-team-b.yaml"]


def test_kustomization_lists_every_tenant():
    with open(os.path.join(ROOT, "kubernetes", "tenants", "kustomization.yaml")) as fh:
        listed = yaml.safe_load(fh)["resources"]
    assert sorted(listed) == [os.path.basename(p) for p in TENANT_FILES]


def test_namespace_enforces_restricted_and_has_quota():
    for path in TENANT_FILES:
        kinds = {d["kind"]: d for d in docs(path)}
        labels = kinds["Namespace"]["metadata"]["labels"]
        assert labels["pod-security.kubernetes.io/enforce"] == "restricted", path
        assert "kif.io/tenant" in labels
        assert "ResourceQuota" in kinds, path


def test_workloads_are_restricted_compliant():
    for path in TENANT_FILES:
        for d in docs(path):
            if d["kind"] != "Deployment":
                continue
            spec = d["spec"]["template"]["spec"]
            assert spec["automountServiceAccountToken"] is False
            assert spec["securityContext"]["runAsNonRoot"] is True
            assert spec["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault"
            for c in spec["containers"]:
                sc = c["securityContext"]
                assert sc["allowPrivilegeEscalation"] is False
                assert sc["capabilities"]["drop"] == ["ALL"]
                assert "limits" in c["resources"] and "requests" in c["resources"]


def test_diagnostic_approval_label_is_explicit():
    """production-debug's admission policy admits its bindings only where the
    platform set production-debug/diagnosable=true; the value must be the
    string "true", not a YAML boolean."""
    for path in TENANT_FILES:
        ns = next(d for d in docs(path) if d["kind"] == "Namespace")
        assert ns["metadata"]["labels"]["production-debug/diagnosable"] == "true", path


def test_only_the_namespace_carries_the_approval_label():
    for path in TENANT_FILES:
        for d in docs(path):
            if d["kind"] != "Namespace":
                labels = d["metadata"].get("labels", {})
                assert "production-debug/diagnosable" not in labels, (path, d["kind"])
