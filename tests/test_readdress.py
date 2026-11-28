"""scripts/readdress.py: re-address the repo after a VM rebuild (DR plan T2)."""

import json
import os
import subprocess
import sys

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPT = os.path.join(ROOT, "scripts", "readdress.py")

INVENTORY = """\
all:
  children:
    control_plane:
      hosts:
        tf-ha-control1:
          ansible_host: 10.97.0.16
        tf-ha-control2:
          ansible_host: 10.97.1.160
    workers:
      hosts:
        tf-ha-worker1:
          ansible_host: 10.97.0.2
"""
HAPROXY = """\
load_balancer_vip: 10.97.3.100
backends:
  - name: tf-ha-control1
    address: 10.97.0.16
  - name: tf-ha-control2
    address: 10.97.1.160
gateway: 10.97.0.1
"""


def listing(**ips):
    vms = [{"name": n, "state": "Running", "ipv4": [ip, "10.244.0.9"]} for n, ip in ips.items()]
    vms.append({"name": "old-stopped", "state": "Stopped", "ipv4": []})
    return {"list": vms}


@pytest.fixture
def repo(tmp_path):
    (tmp_path / "ansible/inventory/group_vars").mkdir(parents=True)
    (tmp_path / "ansible/inventory/hosts.yml").write_text(INVENTORY)
    (tmp_path / "ansible/inventory/group_vars/load_balancers.yml").write_text(HAPROXY)

    def run(lst, *args):
        mp = tmp_path / "multipass.json"
        mp.write_text(json.dumps(lst))
        return subprocess.run(
            [sys.executable, SCRIPT, "--root", str(tmp_path), "--multipass-json", str(mp), *args],
            capture_output=True,
            text=True,
        )

    run.read = lambda rel: (tmp_path / rel).read_text()
    return run


def test_dry_run_changes_nothing(repo):
    result = repo(listing(**{"tf-ha-control1": "10.97.0.20", "tf-ha-control2": "10.97.1.160", "tf-ha-worker1": "10.97.0.2"}))
    assert result.returncode == 0, result.stderr
    assert "10.97.0.16      -> 10.97.0.20" in result.stdout
    assert "dry run" in result.stdout
    assert repo.read("ansible/inventory/hosts.yml") == INVENTORY


def test_apply_rewrites_inventory_and_backends(repo):
    result = repo(
        listing(**{"tf-ha-control1": "10.97.0.20", "tf-ha-control2": "10.97.1.170", "tf-ha-worker1": "10.97.0.2"}),
        "--apply",
    )
    assert result.returncode == 0, result.stderr
    inv = repo.read("ansible/inventory/hosts.yml")
    assert "ansible_host: 10.97.0.20" in inv and "ansible_host: 10.97.1.170" in inv
    lb = repo.read("ansible/inventory/group_vars/load_balancers.yml")
    assert "address: 10.97.0.20" in lb and "address: 10.97.1.170" in lb


def test_whole_addresses_only(repo):
    # 10.97.0.2 (worker) must not touch 10.97.0.20 or the gateway 10.97.0.1,
    # and the static VIP 10.97.3.100 is never rewritten.
    repo(
        listing(**{"tf-ha-control1": "10.97.0.16", "tf-ha-control2": "10.97.1.160", "tf-ha-worker1": "10.97.0.3"}),
        "--apply",
    )
    inv = repo.read("ansible/inventory/hosts.yml")
    assert "ansible_host: 10.97.0.3\n" in inv and "ansible_host: 10.97.0.16" in inv
    lb = repo.read("ansible/inventory/group_vars/load_balancers.yml")
    assert "gateway: 10.97.0.1\n" in lb and "load_balancer_vip: 10.97.3.100" in lb


def test_swapped_addresses_are_handled(repo):
    # control1 gets worker1's old address and vice versa.
    repo(
        listing(**{"tf-ha-control1": "10.97.0.2", "tf-ha-control2": "10.97.1.160", "tf-ha-worker1": "10.97.0.16"}),
        "--apply",
    )
    inv = repo.read("ansible/inventory/hosts.yml")
    assert "tf-ha-control1:\n          ansible_host: 10.97.0.2\n" in inv
    assert "tf-ha-worker1:\n          ansible_host: 10.97.0.16\n" in inv


def test_unchanged_is_a_no_op(repo):
    result = repo(listing(**{"tf-ha-control1": "10.97.0.16", "tf-ha-control2": "10.97.1.160", "tf-ha-worker1": "10.97.0.2"}), "--apply")
    assert result.returncode == 0 and "nothing to do" in result.stdout


@pytest.mark.parametrize(
    "ips, message",
    [
        ({"tf-ha-control1": "10.97.0.20", "tf-ha-control2": "10.97.1.160"}, "tf-ha-worker1: no running VM"),
        ({"tf-ha-control1": "10.97.1.20", "tf-ha-control2": "10.97.1.160", "tf-ha-worker1": "10.97.0.2"}, "changes zone subnet"),
        ({"tf-ha-control1": "10.97.0.9", "tf-ha-control2": "10.97.1.160", "tf-ha-worker1": "10.97.0.9"}, "duplicate new addresses"),
    ],
)
def test_bad_maps_are_refused_and_nothing_is_written(repo, ips, message):
    result = repo(listing(**ips), "--apply")
    assert result.returncode == 1
    assert message in result.stderr
    assert repo.read("ansible/inventory/hosts.yml") == INVENTORY


def test_pod_and_frontend_addresses_are_ignored(repo):
    lst = {"list": [
        {"name": "tf-ha-control1", "ipv4": ["10.244.0.5", "10.97.3.100", "10.97.0.16"]},
        {"name": "tf-ha-control2", "ipv4": ["10.97.1.160"]},
        {"name": "tf-ha-worker1", "ipv4": ["10.97.0.2"]},
    ]}
    assert "nothing to do" in repo(lst).stdout


def test_live_repository_map_matches_multipass_today():
    """The real inventory and multipass agree right now (skipped without multipass)."""
    try:
        out = subprocess.run(["multipass", "list", "--format", "json"], capture_output=True, text=True, timeout=30)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pytest.skip("multipass not available")
    if out.returncode != 0 or not os.path.exists(os.path.join(ROOT, "ansible/inventory/hosts.yml")):
        pytest.skip("no multipass listing or no local inventory")
    result = subprocess.run([sys.executable, SCRIPT], capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stderr
    assert "nothing to do" in result.stdout
