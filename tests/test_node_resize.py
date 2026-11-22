"""In-place worker memory resize (scripts/multipass-node.sh resize, Terraform node_memory).

multipass and kubectl are replaced by stubs that record their calls, so no VM
is touched. Regression context: PRB-2026-11-22-node-memory, action 3.
"""

import json
import os
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "multipass-node.sh"


def nodes_json(not_ready=(), cordoned=()):
    names = ["tf-ha-control1", "tf-ha-worker1", "tf-ha-worker2"]
    return json.dumps({"items": [
        {"metadata": {"name": n},
         "spec": {"unschedulable": True} if n in cordoned else {},
         "status": {"conditions": [{"type": "Ready", "status": "False" if n in not_ready else "True"}]}}
        for n in names
    ]})


@pytest.fixture
def stubs(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "calls.log"
    (bin_dir / "multipass").write_text(f"""#!/bin/sh
echo "multipass $*" >> {log}
[ "$1" = get ] && echo "$STUB_MEMORY"
[ "$1" = info ] && echo "State:          $STUB_STATE"
exit 0
""")
    (bin_dir / "ssh").write_text(f"""#!/bin/sh
echo "ssh $*" >> {log}
exit 255
""")
    (bin_dir / "sleep").write_text("#!/bin/sh\nexit 0\n")
    (bin_dir / "kubectl").write_text(f"""#!/bin/sh
shift 2  # --kubeconfig PATH
echo "kubectl $*" >> {log}
[ "$1 $2" = "get nodes" ] && cat {tmp_path}/nodes.json
[ "$1 $2" = "get node" ] && echo 10.97.0.2
exit 0
""")
    for f in bin_dir.iterdir():
        f.chmod(0o755)
    (tmp_path / "nodes.json").write_text(nodes_json())
    (tmp_path / "meminfo").write_text("MemAvailable:   4194304 kB\n")  # 4096 MiB

    def run(name, memory, current="1.0GiB", not_ready=(), cordoned=(), available_kib=4194304,
            confirm="__same__", state="Stopped"):
        (tmp_path / "nodes.json").write_text(nodes_json(not_ready, cordoned))
        (tmp_path / "meminfo").write_text(f"MemAvailable:   {available_kib} kB\n")
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", STUB_MEMORY=current,
                   STUB_STATE=state, KIF_MEMINFO=str(tmp_path / "meminfo"),
                   XDG_RUNTIME_DIR=str(tmp_path), KIF_SKIP_DAEMON_CHECK="1",
                   KIF_RESIZE_CONFIRM=name if confirm == "__same__" else confirm)
        result = subprocess.run(["bash", str(SCRIPT), "resize", name, memory],
                                capture_output=True, text=True, env=env, check=False)
        calls = log.read_text().splitlines() if log.exists() else []
        log.unlink(missing_ok=True)
        return result, calls
    return run


def mutating(calls):
    return [c for c in calls if re.match(r"(multipass (stop|set|start)|kubectl (cordon|drain|uncordon)|ssh )", c)]


def test_unchanged_size_is_a_no_op(stubs):
    result, calls = stubs("tf-ha-worker1", "1024M", current="1.0GiB")
    assert result.returncode == 0, result.stderr
    assert "nothing to do" in result.stdout
    assert mutating(calls) == []


def test_unchanged_control_plane_is_a_no_op_not_a_refusal(stubs):
    """Terraform creates node_memory for every node; controls must pass through."""
    result, calls = stubs("tf-ha-control1", "2G", current="2.0GiB", confirm="")
    assert result.returncode == 0, result.stderr
    assert mutating(calls) == []


def test_refuses_to_resize_control_plane(stubs):
    result, calls = stubs("tf-ha-control1", "3G", current="2.0GiB")
    assert result.returncode == 1
    assert "etcd quorum" in result.stderr
    assert mutating(calls) == []


def test_refuses_when_another_node_is_not_ready(stubs):
    result, calls = stubs("tf-ha-worker1", "1536M", not_ready=("tf-ha-worker2",))
    assert result.returncode == 1
    assert "not Ready" in result.stderr
    assert mutating(calls) == []


def test_refuses_when_another_node_is_cordoned(stubs):
    """Regression (2026-11-22): worker2 was left cordoned by a failed resize,
    Ready but out of service, and worker1 was drained next."""
    result, calls = stubs("tf-ha-worker1", "1536M", cordoned=("tf-ha-worker2",))
    assert result.returncode == 1
    assert "cordoned" in result.stderr
    assert mutating(calls) == []


def test_refuses_without_host_headroom(stubs):
    # 512 MiB increase needs 512 + 1024 MiB available; only 1200 MiB is.
    result, calls = stubs("tf-ha-worker1", "1536M", available_kib=1200 * 1024)
    assert result.returncode == 1
    assert "margin" in result.stderr
    assert mutating(calls) == []


def test_resize_drains_before_stopping_and_uncordons_last(stubs):
    result, calls = stubs("tf-ha-worker1", "1536M")
    assert result.returncode == 0, result.stderr
    steps = ["poweroff" if c.startswith("ssh ") else c.split()[1] for c in mutating(calls)]
    assert steps == ["cordon", "drain", "poweroff", "set", "start", "uncordon"]
    assert any("ubuntu@10.97.0.2 sudo systemctl poweroff" in c for c in calls)
    assert "multipass set local.tf-ha-worker1.memory=1536M" in calls
    assert any(c.startswith("kubectl wait --for=condition=Ready node/tf-ha-worker1") for c in calls)


def test_never_uses_multipass_stop():
    """multipassd 1.17.2 crashed on `multipass stop` (INC-2026-11-22-api-outage-multipassd)."""
    body = SCRIPT.read_text().split("  resize)")[1].split("\n  *)")[0]
    assert not re.search(r"^\s*multipass stop", body, re.M)


@pytest.mark.parametrize("confirm", ["", "tf-ha-worker2"])
def test_refuses_without_confirmation_for_this_node(stubs, confirm):
    result, calls = stubs("tf-ha-worker1", "1536M", confirm=confirm)
    assert result.returncode == 1
    assert "KIF_RESIZE_CONFIRM=tf-ha-worker1" in result.stderr
    assert mutating(calls) == []


def test_guest_that_does_not_stop_is_left_cordoned_without_force(stubs):
    result, calls = stubs("tf-ha-worker1", "1536M", state="Running")
    assert result.returncode == 1
    assert "did not reach Stopped" in result.stderr
    steps = ["poweroff" if c.startswith("ssh ") else c.split()[1] for c in mutating(calls)]
    assert steps == ["cordon", "drain", "poweroff"]


def test_terraform_never_replaces_a_vm_for_a_memory_change():
    tf = (ROOT / "terraform" / "main.tf").read_text()
    triggers = re.search(r'resource "terraform_data" "kubernetes_node".*?triggers_replace = \[(.*?)\]', tf, re.S).group(1)
    assert "launch_memory" in triggers
    assert "each.value.memory" not in triggers
    assert 'multipass-node.sh\' resize' in tf
