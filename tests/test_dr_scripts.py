"""DR automation (scripts/dr): dry runs change nothing; verification catches loss."""

import copy
import json
import os
import subprocess
import sys

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DR = os.path.join(ROOT, "scripts", "dr")

# Every command a phase script could use to change state. In a dry run none
# of them may be called at all.
DANGEROUS = ["terraform", "multipass", "sudo", "ansible-playbook", "ansible", "kubectl",
             "vault", "gpg", "shred", "install", "ssh-keygen"]


def state(**over):
    s = {
        "captured_at": "2026-11-28T05:00:00Z",
        "identity": {"cluster_ca_pubkey_sha256": "a" * 64, "sa_pub_sha256": "b" * 64},
        "nodes": [{"name": f"n{i}", "ready": True} for i in range(5)],
        "objects": {
            "namespaces": {"count": 3, "names": ["app-team-a", "debug-system", "kube-system"]},
            "deployments": {"count": 1, "names": ["kube-system/coredns"]},
            "secrets": {"count": 8, "names": None},
        },
        "access_model": {"debug_grants": [], "access_guard_rules": 5, "grant_reaper_cronjob": True,
                         "diagnosable_namespaces": ["app-team-a"]},
        "vault": {"sealed": False, "version": "2.2.2", "initialized": True},
        "monitoring": {"targets": 15, "up": 15},
    }
    s.update(over)
    return s


def compare(tmp_path, before, after):
    b, a = tmp_path / "b.json", tmp_path / "a.json"
    b.write_text(json.dumps(before))
    a.write_text(json.dumps(after))
    return subprocess.run([sys.executable, os.path.join(DR, "compare-state.py"), str(b), str(a)],
                          capture_output=True, text=True)


def test_identical_state_passes(tmp_path):
    r = compare(tmp_path, state(), state())
    assert r.returncode == 0, r.stdout
    assert "FAIL" not in r.stdout


def test_a_lost_object_fails(tmp_path):
    after = state()
    after["objects"]["namespaces"] = {"count": 2, "names": ["debug-system", "kube-system"]}
    r = compare(tmp_path, state(), after)
    assert r.returncode == 1
    assert "missing after: app-team-a" in r.stdout


def test_a_new_cluster_identity_fails(tmp_path):
    after = copy.deepcopy(state())
    after["identity"]["cluster_ca_pubkey_sha256"] = "c" * 64
    r = compare(tmp_path, state(), after)
    assert r.returncode == 1 and "FAIL | identity: cluster_ca_pubkey_sha256" in r.stdout


def test_new_objects_are_a_note_not_a_failure(tmp_path):
    after = state()
    after["objects"]["deployments"] = {"count": 2, "names": ["kube-system/coredns", "kube-system/extra"]}
    r = compare(tmp_path, state(), after)
    assert r.returncode == 0 and "NOTE | deployments" in r.stdout


def test_objects_left_by_the_tests_are_ignored(tmp_path):
    after = state()
    after["objects"]["namespaces"] = {"count": 4, "names": ["app-team-a", "debug-system", "kube-system", "pd-guard-approved"]}
    r = compare(tmp_path, state(), after)
    assert "NOTE | namespaces" not in r.stdout and r.returncode == 0


@pytest.mark.parametrize("change", [
    lambda s: s["vault"].update(sealed=True),
    lambda s: s["nodes"][0].update(ready=False),
    lambda s: s["monitoring"].update(up=14),
    lambda s: s["access_model"].update(grant_reaper_cronjob=False),
    lambda s: s["objects"]["secrets"].update(count=3),
])
def test_other_regressions_fail(tmp_path, change):
    after = copy.deepcopy(state())
    change(after)
    assert compare(tmp_path, state(), after).returncode == 1


# --- dry runs ------------------------------------------------------------------

@pytest.fixture
def dry(tmp_path):
    fakes = tmp_path / "fakes"
    fakes.mkdir()
    calls = tmp_path / "calls"
    calls.touch()
    for name in DANGEROUS:
        f = fakes / name
        f.write_text(f'#!/bin/sh\necho "{name} $*" >> "{calls}"\nexit 0\n')
        f.chmod(0o755)
    run_dir = tmp_path / "run"
    run_dir.mkdir()
    (run_dir / "preflight.md").write_text("GO: every automated check passed.\n")
    (run_dir / "before.json").write_text(json.dumps(state()))
    (run_dir / "load-balancers.json").write_text(json.dumps({
        "api_lb1": {"name": "api-lb1-new", "zone": "zone2", "cpus": 1, "memory_bytes": 731987968,
                    "disk_bytes": 5120138752, "frontend_ip": "10.97.3.11"}}))
    (run_dir / "ubuntu-image").write_text("26.04\n")
    (run_dir / "hosts.before.yml").write_text("")
    (run_dir / "timing.tsv").write_text("phase\tevent\tutc\tepoch\tstatus\n")
    usb = tmp_path / "usb"
    (usb / "kif-vault").mkdir(parents=True)
    (usb / "kif-dr").mkdir()
    (usb / "kif-vault" / "kif-vault-20261129T000000Z.snap.gpg").write_text("x")
    (usb / "kif-dr" / "kif-host-pki-20261128.tar.gpg").write_text("x")

    def run(script, *args):
        env = {"PATH": f"{fakes}:/usr/bin:/bin", "HOME": str(tmp_path), "DR_RUN_DIR": str(run_dir),
               "DR_USB": str(usb)}
        return subprocess.run(["bash", os.path.join(DR, script), *args], capture_output=True, text=True, env=env)

    run.calls = lambda: calls.read_text()
    run.run_dir = run_dir
    return run


@pytest.mark.parametrize("script", ["20-destroy.sh", "30-rebuild.sh", "40-restore-cluster.sh", "50-restore-vault.sh"])
def test_dry_run_changes_nothing(dry, script):
    result = dry(script)
    assert result.returncode == 0, result.stderr
    assert "[dry-run]" in result.stdout
    assert dry.calls() == "", f"{script} called a state-changing command in a dry run:\n{dry.calls()}"


def test_destroy_dry_run_lists_the_point_of_no_return(dry):
    out = dry("20-destroy.sh").stdout
    assert "[dry-run] terraform -chdir=" in out and "destroy -auto-approve" in out
    assert "[dry-run] multipass delete --purge api-lb1-new" in out
    for path in ("/opt/vault/data", "/opt/vault/tls", "/etc/vault.d/vault.hcl"):
        assert f"sudo mv {path} " in out, path


def test_destroy_refuses_without_a_go_preflight(dry):
    (dry.run_dir / "preflight.md").write_text("NO-GO: fix the FAIL items above.\n")
    result = dry("20-destroy.sh", "--execute")
    assert result.returncode != 0
    assert "was not GO" in result.stderr
    assert dry.calls() == ""


def test_rebuild_uses_the_recorded_lb_and_pins_host_keys(dry):
    out = dry("30-rebuild.sh").stdout
    assert "LB_REBUILD=1" in out and "create api-lb1-new zone2 1 731987968 5120138752 26.04 10.97.3.11" in out
    assert "readdress.py --apply" in out
    assert "trust-host-keys.sh" in out


def test_restore_checks_the_recorded_ca(dry):
    out = dry("40-restore-cluster.sh").stdout
    assert f"dr_expected_ca_pubkey_sha256={'a' * 64}" in out
    assert out.index("17-restore-control-plane.yml") < out.index("07-join-control-planes.yml") < out.index("08-join-workers.yml")


def test_timing_report(dry):
    tsv = dry.run_dir / "timing.tsv"
    tsv.write_text("phase\tevent\tutc\tepoch\tstatus\n"
                   "1-destroy\tstart\t2026-11-29T10:00:00Z\t1000\tok\n"
                   "1-destroy\tend\t2026-11-29T10:04:05Z\t1245\tok\n")
    out = subprocess.run(["bash", "-c", f'DR_RUN_DIR="{dry.run_dir}"; . "{DR}/lib.sh"; dr_timing_report'],
                         capture_output=True, text=True).stdout
    assert "| 1-destroy | 2026-11-29T10:00:00Z | 2026-11-29T10:04:05Z | 4 min 5 s | ok |" in out


def test_destroy_previews_even_when_not_go(dry):
    (dry.run_dir / "preflight.md").write_text("NO-GO: fix the FAIL items above.\n")
    result = dry("20-destroy.sh")
    assert result.returncode == 0 and "preview only" in result.stdout
    assert dry.calls() == ""
