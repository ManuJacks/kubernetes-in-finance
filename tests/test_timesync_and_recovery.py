"""Regression tests for the 2026-11-21 clock-drift incident.

See docs/incidents/2026-11-21-clock-drift-after-host-suspend.md.
"""

import json
import os
import shutil
import subprocess

import pytest
import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ANSIBLE = os.path.join(ROOT, "ansible")


def load(*parts):
    with open(os.path.join(ANSIBLE, *parts)) as f:
        return yaml.safe_load(f)


def role_names(play):
    return [r if isinstance(r, str) else r.get("role") for r in play.get("roles", [])]


def task_by_name(tasks, prefix):
    matches = [t for t in tasks if t.get("name", "").startswith(prefix)]
    assert matches, f"task starting with {prefix!r} not found"
    return matches[0]


# --- time synchronisation -------------------------------------------------


def test_makestep_allows_stepping_after_startup():
    """The Ubuntu default 'makestep 1 3' left resumed VMs hours off."""
    defaults = load("roles", "timesync", "defaults", "main.yml")
    assert defaults["timesync_makestep_limit"] == -1
    assert 0 < float(defaults["timesync_makestep_threshold_seconds"]) <= 1.0

    tasks = load("roles", "timesync", "tasks", "main.yml")
    makestep = task_by_name(tasks, "Allow chrony to step")
    lineinfile = makestep["ansible.builtin.lineinfile"]
    assert lineinfile["regexp"].lstrip("^\\s*").startswith("makestep")
    assert "timesync_makestep_limit" in lineinfile["line"]
    validate = lineinfile["validate"]
    assert "%s" in validate and "chronyd -p -f" in validate
    # AppArmor confines chronyd to /etc/chrony; validation must read from there.
    assert "/etc/chrony/" in validate.split("chronyd -p -f", 1)[1]


def test_timesync_role_fails_when_clock_is_out_of_tolerance():
    defaults = load("roles", "timesync", "defaults", "main.yml")
    assert float(defaults["timesync_max_offset_seconds"]) <= 1.0

    tasks = load("roles", "timesync", "tasks", "main.yml")
    gate = task_by_name(tasks, "Assert the clock is synchronised")
    conditions = " ".join(gate["ansible.builtin.assert"]["that"])
    assert "timesync_max_offset_seconds" in conditions
    assert "Not synchronised" in conditions


def test_timesync_applied_to_every_host_group():
    common = load("playbooks", "01-common.yml")[0]
    assert common["hosts"] == "kubernetes"
    assert "timesync" in role_names(common)

    lbs = load("playbooks", "02-load-balancers.yml")[0]
    assert lbs["hosts"] == "load_balancers"
    names = role_names(lbs)
    assert names.index("timesync") < names.index("haproxy")


def test_time_sync_rollout_is_one_host_at_a_time_with_health_checks():
    plays = load("playbooks", "11-time-sync.yml")
    rollout = plays[0]
    assert rollout["serial"] == 1
    assert rollout["any_errors_fatal"] is True
    for group in ("load_balancers", "control_plane", "workers"):
        assert group in rollout["hosts"]
    post = " ".join(t["name"] for t in rollout["post_tasks"])
    assert "API server is live" in post
    assert "etcd member health" in post

    agreement = plays[1]
    assert any("agree within tolerance" in t["name"] for t in agreement["tasks"])


# --- stuck static pod recovery --------------------------------------------


def test_recovery_requires_explicit_single_control_plane_target():
    play = load("playbooks", "12-recover-static-pod.yml")[0]
    guard = task_by_name(play["tasks"], "Require an explicit control-plane target")
    conditions = guard["ansible.builtin.assert"]["that"]
    assert "recover_target is defined" in conditions
    assert "recover_target in groups['control_plane']" in conditions


def test_recovery_refuses_unless_stuck_reservation_state_is_present():
    play = load("playbooks", "12-recover-static-pod.yml")[0]
    tasks = play["tasks"]
    names = [t["name"] for t in tasks]
    refuse = names.index("Refuse unless the stuck-reservation condition is present")
    remove = names.index("Remove stale exited containers (re-checking each is still exited)")
    assert refuse < remove, "preflight refusal must run before any removal"

    conditions = tasks[refuse]["ansible.builtin.assert"]["that"]
    assert "recover_waiting_reason == 'CreateContainerError'" in conditions
    assert "recover_running | length == 1" in conditions
    assert "recover_stale | length >= 1" in conditions


def test_recovery_never_stops_or_restarts_anything():
    text = open(os.path.join(ANSIBLE, "playbooks", "12-recover-static-pod.yml")).read()
    for forbidden in ("crictl stop", "crictl rmp", "state: restarted", "state: stopped", "rm -f"):
        assert forbidden not in text, forbidden


def test_recovery_preserves_logs_before_removal():
    tasks = load("playbooks", "12-recover-static-pod.yml")[0]["tasks"]
    names = [t["name"] for t in tasks]
    assert names.index("Preserve logs of stale exited containers") < names.index(
        "Remove stale exited containers (re-checking each is still exited)"
    )
    remove = task_by_name(tasks, "Remove stale exited containers")
    assert "CONTAINER_EXITED" in remove["ansible.builtin.shell"]["cmd"]


def _select(containers):
    tasks = load("playbooks", "12-recover-static-pod.yml")[0]["tasks"]
    flt = task_by_name(tasks, "Identify the running container")["environment"]["RECOVER_SELECT"]
    out = subprocess.run(
        ["jq", "-c", "--arg", "uid", "uid-1", flt],
        input=json.dumps({"containers": containers}),
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    result = json.loads(out)
    return [c["id"] for c in result["running"]], [c["id"] for c in result["stale"]]


def _c(cid, state, created, uid="uid-1"):
    return {"id": cid, "state": state, "createdAt": created,
            "metadata": {"attempt": 0}, "labels": {"io.kubernetes.pod.uid": uid}}


@pytest.mark.skipif(shutil.which("jq") is None, reason="jq not installed")
@pytest.mark.parametrize(
    "containers,expected_stale",
    [
        # Observed on tf-ha-control2: exited attempt 188 has a later createdAt
        # than running attempt 189 because the clock jumped backwards.
        ([_c("a188", "CONTAINER_EXITED", "1795023874674674538"),
          _c("r189", "CONTAINER_RUNNING", "1795006981848075111")], ["a188"]),
        # Healthy history: exited container is older; nothing to remove.
        ([_c("a188", "CONTAINER_EXITED", "1795000000000000000"),
          _c("r189", "CONTAINER_RUNNING", "1795006981848075111")], []),
        # Containers from another pod are never selected.
        ([_c("x", "CONTAINER_EXITED", "1795099999000000000", uid="other"),
          _c("r189", "CONTAINER_RUNNING", "1795006981848075111")], []),
        # Without exactly one running container nothing is selected.
        ([_c("a188", "CONTAINER_EXITED", "1795023874674674538")], []),
    ],
)
def test_stale_container_selection(containers, expected_stale):
    _, stale = _select(containers)
    assert stale == expected_stale
