"""Guards for the external Vault Kubernetes auth integration (ADR-007)."""

import os
import re

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ROLE = os.path.join(ROOT, "ansible", "roles", "vault-kubernetes-prereqs")


def read(*parts):
    with open(os.path.join(ROOT, *parts)) as fh:
        return fh.read()


def policy_paths(name):
    return re.findall(r'^path\s+"([^"]+)"', read("vault", "policies", f"{name}.hcl"), re.M)


def test_application_policy_never_reaches_database_paths():
    paths = policy_paths("production-debug-secrets")
    assert paths, "application policy has no paths"
    for p in paths:
        assert "/production-debug/application" in p, p
        assert "database" not in p, p


def test_policies_are_read_only():
    for name in ("production-debug-secrets", "production-debug-db-audit"):
        for caps in re.findall(r"capabilities\s*=\s*\[([^\]]*)\]", read("vault", "policies", f"{name}.hcl")):
            assert set(re.findall(r'"(\w+)"', caps)) <= {"read", "list"}, (name, caps)


def test_reviewer_gets_only_auth_delegator_and_a_long_lived_token():
    # Strip Jinja so the template parses as YAML.
    text = re.sub(r"\{\{\s*(\w+)\s*\}\}", r"\1", read(ROLE, "templates", "token-reviewer.yaml.j2"))
    docs = {d["kind"]: d for d in yaml.safe_load_all(text) if d}
    assert set(docs) == {"ServiceAccount", "ClusterRoleBinding", "Secret"}
    assert docs["ClusterRoleBinding"]["roleRef"]["name"] == "system:auth-delegator"
    secret = docs["Secret"]
    assert secret["type"] == "kubernetes.io/service-account-token"
    assert secret["metadata"]["annotations"]["kubernetes.io/service-account.name"] == "vault_token_reviewer_serviceaccount"


def test_runbook_does_not_configure_vault_with_a_short_lived_reviewer_token():
    runbook = read("docs", "runbooks", "vault-kubernetes-auth.md")
    assert "TOKEN_REVIEWER_JWT=\"$(kubectl -n kube-system create token" not in runbook
    assert "vault-token-reviewer-token" in runbook


def test_playbook_never_contacts_vault():
    for f in ("tasks/main.yml",):
        text = read(ROLE, f)
        assert "vault " not in text and "VAULT_ADDR" not in text and "8200" not in text, f
    # The API endpoint comes from the kubeconfig, not a hardcoded address.
    assert "10.97.3.100" not in read(ROLE, "tasks", "main.yml")
