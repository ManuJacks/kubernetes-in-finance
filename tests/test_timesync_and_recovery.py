"""Regression tests for the 2026-11-21 clock-drift incident.

See docs/incidents/2026-11-21-clock-drift-after-host-suspend.md.
"""

import os

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
    assert "chronyd -p -f %s" in lineinfile["validate"]


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
    restart = names.index("Restart kubelet so it re-lists and adopts the running container")
    assert refuse < restart, "preflight refusal must run before any restart"

    conditions = tasks[refuse]["ansible.builtin.assert"]["that"]
    assert "recover_waiting_reason == 'CreateContainerError'" in conditions
    assert "recover_running_count | int == 1" in conditions


def test_recovery_restarts_containerd_only_when_requested():
    play = load("playbooks", "12-recover-static-pod.yml")[0]
    assert play["vars"]["recover_restart_containerd"] is False
    task = task_by_name(play["tasks"], "Optionally restart containerd")
    assert task["when"] == "recover_restart_containerd | bool"
