"""Static guards for the vault-server role (DR plan gap T5)."""

import os
import re

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ROLE = os.path.join(ROOT, "ansible", "roles", "vault-server")


def read(*parts):
    with open(os.path.join(*parts)) as f:
        return f.read()


def test_package_version_is_pinned_and_held():
    defaults = yaml.safe_load(read(ROLE, "defaults", "main.yml"))
    assert re.fullmatch(r"\d+\.\d+\.\d+-\d+", defaults["vault_version"])
    tasks = read(ROLE, "tasks", "main.yml")
    assert 'name: "vault={{ vault_version }}"' in tasks
    assert "selection: hold" in tasks


def test_no_key_material_in_the_role():
    for dirpath, _, files in os.walk(ROLE):
        for name in files:
            text = read(dirpath, name)
            assert "BEGIN" not in text and "PRIVATE KEY" not in text, name


def test_config_keeps_tls_and_raft_settings():
    tpl = read(ROLE, "templates", "vault.hcl.j2")
    assert 'storage "raft"' in tpl
    assert 'tls_min_version = "tls12"' in tpl
    assert "tls_disable" not in tpl


def test_role_never_unseals_or_initialises():
    code = "\n".join(
        line for line in read(ROLE, "tasks", "main.yml").splitlines() if not line.lstrip().startswith("#")
    )
    for forbidden in ("operator unseal", "operator init", "unseal_keys", "raft snapshot restore"):
        assert forbidden not in code


def test_pki_backup_is_encrypted_to_an_offline_key():
    script = read(ROOT, "ansible", "roles", "etcd-backup", "templates", "etcd-backup.sh.j2")
    assert "--recipient-file" in script and "--encrypt" in script
    defaults = yaml.safe_load(read(ROOT, "ansible", "roles", "etcd-backup", "defaults", "main.yml"))
    assert {"ca.key", "sa.key", "front-proxy-ca.key", "etcd/ca.key"} <= set(defaults["etcd_backup_pki_files"])


def test_template_has_no_extra_header():
    """A header would differ from the live file; the change would restart and seal Vault."""
    assert read(ROLE, "templates", "vault.hcl.j2").startswith("ui = true\n")
