"""scripts/multipass-load-balancer.sh: rebuilding recorded LBs (DR plan T15, T16)."""

import os
import subprocess

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPT = os.path.join(ROOT, "scripts", "multipass-load-balancer.sh")

FAKE_MULTIPASS = r"""#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$1" in
  info) [ -f "$CALLS.launched" ] || exit 1 ;;        # exists only after launch
  zones) printf 'Name\nzone1\nzone2\nzone3\n' ;;
  networks) printf 'Name Type\nbr-api-frontend bridge\n' ;;
  list) echo '{"list": []}' ;;
  launch)
    touch "$CALLS.launched"
    for a in "$@"; do case "$prev" in --cloud-init) cp "$a" "$CALLS.cloud-init" ;; esac; prev="$a"; done ;;
  exec)
    case "$*" in
      *"ip -4 -o addr show dev eth1"*) echo "3: eth1 inet $FAKE_IP/24 brd 10.97.3.255" ;;
      *"tee"*) cat >/dev/null ;;
    esac ;;
esac
exit 0
"""


@pytest.fixture
def lb(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "multipass").write_text(FAKE_MULTIPASS)
    (bin_dir / "multipass").chmod(0o755)
    key = tmp_path / "id.pub"
    key.write_text("ssh-ed25519 AAAATESTKEY ansible@kif\n")
    calls = tmp_path / "calls"
    calls.touch()

    def run(name, ip, rebuild=None):
        env = {
            "PATH": f"{bin_dir}:/usr/bin:/bin",
            "CALLS": str(calls),
            "FAKE_IP": ip,
            "K8S_FINANCE_SSH_PUBLIC_KEY": str(key),
        }
        if rebuild is not None:
            env["LB_REBUILD"] = rebuild
        return subprocess.run(
            ["bash", SCRIPT, "create", name, "zone2", "1", "731987968", "5120138752", "26.04", ip],
            capture_output=True,
            text=True,
            env=env,
        )

    run.calls = lambda: calls.read_text()
    run.cloud_init = lambda: (tmp_path / "calls.cloud-init").read_text()
    return run


def test_recorded_address_is_refused_for_a_new_lb(lb):
    result = lb("api-lb1-new", "10.97.3.11")
    assert result.returncode == 1
    assert "reserved for a recorded load balancer" in result.stderr
    assert "launch" not in lb.calls()


@pytest.mark.parametrize("name, ip", [("api-lb1-new", "10.97.3.11"), ("api-lb2-new", "10.97.3.12")])
def test_rebuild_allows_exactly_the_recorded_address(lb, name, ip):
    result = lb(name, ip, rebuild="1")
    assert result.returncode == 0, result.stderr
    assert "Rebuilding recorded load balancer" in result.stdout
    assert "launch" in lb.calls()


@pytest.mark.parametrize("name, ip", [("api-lb1-new", "10.97.3.12"), ("api-lb3-new", "10.97.3.11")])
def test_rebuild_refuses_someone_elses_address(lb, name, ip):
    result = lb(name, ip, rebuild="1")
    assert result.returncode == 1
    assert "launch" not in lb.calls()


def test_vip_is_never_allowed(lb):
    assert lb("api-lb1-new", "10.97.3.100", rebuild="1").returncode == 1


def test_new_lb_on_a_free_address_still_works(lb):
    assert lb("api-lb3-new", "10.97.3.13").returncode == 0


def test_lb_gets_the_ansible_ssh_key(lb):
    assert lb("api-lb3-new", "10.97.3.13").returncode == 0
    cloud_init = lb.cloud_init()
    assert cloud_init.startswith("#cloud-config")
    assert "ssh-ed25519 AAAATESTKEY ansible@kif" in cloud_init
