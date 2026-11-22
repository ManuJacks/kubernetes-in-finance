"""Regressions for INC-2026-11-22-worker2-memory (docs/incidents/)."""

import os
import re

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ROLES = os.path.join(ROOT, "ansible", "roles")


def role_files():
    for dirpath, _, files in os.walk(ROLES):
        for name in files:
            if name.endswith((".yml", ".yaml", ".j2")):
                yield os.path.join(dirpath, name)


def test_no_role_downloads_into_tmp():
    """/tmp is tmpfs on the nodes: anything left there is held in RAM."""
    offenders = []
    for path in role_files():
        with open(path) as f:
            for number, line in enumerate(f, 1):
                if re.search(r"""(_dir|dest|path)\s*:\s*["']?/tmp/""", line):
                    offenders.append(f"{os.path.relpath(path, ROOT)}:{number}: {line.strip()}")
    assert not offenders, "role writes persistent files under /tmp:\n" + "\n".join(offenders)


def test_nodes_do_not_run_background_apt():
    with open(os.path.join(ROLES, "common", "tasks", "main.yml")) as f:
        tasks = yaml.safe_load(f)
    by_name = {t["name"]: t for t in tasks}
    periodic = by_name["Disable periodic APT updates and unattended upgrades"]["ansible.builtin.copy"]["content"]
    assert 'Update-Package-Lists "0"' in periodic
    assert 'Unattended-Upgrade "0"' in periodic
    timers = by_name["Stop and disable APT timers and the unattended-upgrades service"]
    assert {"apt-daily.timer", "apt-daily-upgrade.timer"} <= set(timers["loop"])
    assert timers["ansible.builtin.systemd_service"]["enabled"] is False
    motd = by_name["Find login MOTD scripts that run apt or network checks"]["ansible.builtin.find"]
    assert "90-updates-available" in motd["patterns"]
