import os
import stat
import subprocess
import tempfile
import pytest

SCRIPT_TEMPLATE_PATH = os.path.abspath(
    os.path.join(
        os.path.dirname(__file__),
        "../ansible/roles/etcd-backup/templates/etcd-backup.sh.j2",
    )
)

SYSTEMD_SERVICE_TEMPLATE_PATH = os.path.abspath(
    os.path.join(
        os.path.dirname(__file__),
        "../ansible/roles/etcd-backup/templates/etcd-backup.service.j2",
    )
)

SYSTEMD_TIMER_TEMPLATE_PATH = os.path.abspath(
    os.path.join(
        os.path.dirname(__file__),
        "../ansible/roles/etcd-backup/templates/etcd-backup.timer.j2",
    )
)


def test_templates_exist():
    assert os.path.isfile(SCRIPT_TEMPLATE_PATH), "Backup script template missing"
    assert os.path.isfile(SYSTEMD_SERVICE_TEMPLATE_PATH), "Service template missing"
    assert os.path.isfile(SYSTEMD_TIMER_TEMPLATE_PATH), "Timer template missing"


def test_script_execution_and_retention():
    with open(SCRIPT_TEMPLATE_PATH, "r") as f:
        content = f.read()

    with tempfile.TemporaryDirectory() as tmpdir:
        backup_dir = os.path.join(tmpdir, "backups")
        os.makedirs(backup_dir, exist_ok=True)

        cert_dir = os.path.join(tmpdir, "pki")
        os.makedirs(cert_dir, exist_ok=True)
        ca_cert = os.path.join(cert_dir, "ca.crt")
        cert = os.path.join(cert_dir, "server.crt")
        key = os.path.join(cert_dir, "server.key")
        for cert_file in [ca_cert, cert, key]:
            with open(cert_file, "w") as f:
                f.write("DUMMY_CERT")

        # Mock bin directory for etcdctl and etcdutl
        bin_dir = os.path.join(tmpdir, "bin")
        os.makedirs(bin_dir, exist_ok=True)

        mock_etcdctl = os.path.join(bin_dir, "etcdctl")
        with open(mock_etcdctl, "w") as f:
            f.write(
                "#!/bin/bash\n"
                'target="${@: -1}"\n'
                'touch "$target"\n'
                'echo "Snapshot saved to $target"\n'
                "exit 0\n"
            )
        os.chmod(mock_etcdctl, stat.S_IRWXU)

        mock_etcdutl = os.path.join(bin_dir, "etcdutl")
        with open(mock_etcdutl, "w") as f:
            f.write(
                "#!/bin/bash\n"
                'echo "+------------+----------+---------------+"\n'
                'echo "|    HASH    | REVISION | TOTAL KEYS |"\n'
                'echo "+------------+----------+---------------+"\n'
                'echo "| 0x1234abcd |        1 |        100 |"\n'
                'echo "+------------+----------+---------------+"\n'
                "exit 0\n"
            )
        os.chmod(mock_etcdutl, stat.S_IRWXU)

        node_name = "test-node-1"
        # Pre-create an old backup file for this node that should be pruned
        old_backup = os.path.join(backup_dir, f"etcd-snapshot-{node_name}-20200101_000000Z.db")
        with open(old_backup, "w") as f:
            f.write("OLD_BACKUP")
        old_time = 1577836800  # 2020-01-01
        os.utime(old_backup, (old_time, old_time))

        # Pre-create an old backup for ANOTHER node that should NOT be pruned by this node
        other_node_backup = os.path.join(backup_dir, "etcd-snapshot-other-node-20200101_000000Z.db")
        with open(other_node_backup, "w") as f:
            f.write("OTHER_NODE_BACKUP")
        os.utime(other_node_backup, (old_time, old_time))

        # Render template replacements without mount requirement
        rendered_script = (
            content.replace("{{ etcd_backup_dir }}", backup_dir)
            .replace("{{ etcd_backup_endpoint }}", "https://127.0.0.1:2379")
            .replace("{{ etcd_backup_ca_cert }}", ca_cert)
            .replace("{{ etcd_backup_cert }}", cert)
            .replace("{{ etcd_backup_key }}", key)
            .replace("{{ etcd_backup_retention_days }}", "7")
            .replace("{{ 'true' if (etcd_backup_require_mount | bool or etcd_backup_use_nfs | bool) else 'false' }}", "false")
            .replace("/usr/local/bin/etcdctl", mock_etcdctl)
            .replace("/usr/local/bin/etcdutl", mock_etcdutl)
        )

        test_script_path = os.path.join(tmpdir, "run-backup.sh")
        with open(test_script_path, "w") as f:
            f.write(rendered_script)
        os.chmod(test_script_path, stat.S_IRWXU)

        env = os.environ.copy()
        env["NODE_NAME"] = node_name

        # Run the script
        result = subprocess.run(
            [test_script_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )

        assert result.returncode == 0, f"Script failed: stdout={result.stdout}, stderr={result.stderr}"
        assert f"Starting etcd backup for node '{node_name}'" in result.stdout
        assert "etcd backup completed successfully" in result.stdout

        # Verify new backup was created with node name in filename
        backups = [
            b
            for b in os.listdir(backup_dir)
            if b.startswith(f"etcd-snapshot-{node_name}-") and b.endswith(".db")
        ]
        assert len(backups) == 1, f"Expected 1 snapshot for {node_name}, found: {backups}"
        assert not os.path.exists(
            old_backup
        ), "Old backup for this node was not pruned"
        assert os.path.exists(
            other_node_backup
        ), "Backup belonging to a different node was incorrectly deleted"


def test_mountpoint_guardrail_failure():
    with open(SCRIPT_TEMPLATE_PATH, "r") as f:
        content = f.read()

    with tempfile.TemporaryDirectory() as tmpdir:
        non_mount_dir = os.path.join(tmpdir, "non-mount-backups")
        os.makedirs(non_mount_dir, exist_ok=True)

        rendered_script = (
            content.replace("{{ etcd_backup_dir }}", non_mount_dir)
            .replace("{{ etcd_backup_endpoint }}", "https://127.0.0.1:2379")
            .replace("{{ etcd_backup_ca_cert }}", "/tmp/dummy.crt")
            .replace("{{ etcd_backup_cert }}", "/tmp/dummy.crt")
            .replace("{{ etcd_backup_key }}", "/tmp/dummy.key")
            .replace("{{ etcd_backup_retention_days }}", "7")
            .replace("{{ 'true' if (etcd_backup_require_mount | bool or etcd_backup_use_nfs | bool) else 'false' }}", "true")
        )

        test_script_path = os.path.join(tmpdir, "run-backup-fail.sh")
        with open(test_script_path, "w") as f:
            f.write(rendered_script)
        os.chmod(test_script_path, stat.S_IRWXU)

        result = subprocess.run(
            [test_script_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        assert result.returncode != 0
        assert "is not a mount point and external storage is required" in result.stderr
