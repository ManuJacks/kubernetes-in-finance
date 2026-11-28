import os
import shutil
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

            .replace("{{ etcd_backup_pki_dir }}", "/nonexistent")

            .replace("{{ etcd_backup_pki_recipient_path }}", "")

            .replace("{{ etcd_backup_pki_files | join(' ') }}", "ca.crt")
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

            .replace("{{ etcd_backup_pki_dir }}", "/nonexistent")

            .replace("{{ etcd_backup_pki_recipient_path }}", "")

            .replace("{{ etcd_backup_pki_files | join(' ') }}", "ca.crt")
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


def _render(backup_dir, pki_dir, recipient, bin_dir, cert_dir):
    with open(SCRIPT_TEMPLATE_PATH) as f:
        content = f.read()
    return (
        content.replace("{{ etcd_backup_dir }}", backup_dir)
        .replace("{{ etcd_backup_endpoint }}", "https://127.0.0.1:2379")
        .replace("{{ etcd_backup_ca_cert }}", os.path.join(cert_dir, "ca.crt"))
        .replace("{{ etcd_backup_cert }}", os.path.join(cert_dir, "server.crt"))
        .replace("{{ etcd_backup_key }}", os.path.join(cert_dir, "server.key"))
        .replace("{{ etcd_backup_retention_days }}", "7")
        .replace(
            "{{ 'true' if (etcd_backup_require_mount | bool or etcd_backup_use_nfs | bool) else 'false' }}",
            "false",
        )
        .replace("{{ etcd_backup_pki_dir }}", pki_dir)
        .replace("{{ etcd_backup_pki_recipient_path }}", recipient)
        .replace("{{ etcd_backup_pki_files | join(' ') }}", "ca.crt ca.key sa.key etcd/ca.key")
        .replace("/usr/local/bin/etcdctl", os.path.join(bin_dir, "etcdctl"))
        .replace("/usr/local/bin/etcdutl", os.path.join(bin_dir, "etcdutl"))
    )


def _fixture(tmpdir):
    backup_dir = os.path.join(tmpdir, "backups")
    cert_dir = os.path.join(tmpdir, "certs")
    pki_dir = os.path.join(tmpdir, "pki")
    bin_dir = os.path.join(tmpdir, "bin")
    for d in (backup_dir, cert_dir, os.path.join(pki_dir, "etcd"), bin_dir):
        os.makedirs(d, exist_ok=True)
    for name in ("ca.crt", "server.crt", "server.key"):
        with open(os.path.join(cert_dir, name), "w") as f:
            f.write("DUMMY")
    for name in ("ca.crt", "ca.key", "sa.key", "etcd/ca.key"):
        with open(os.path.join(pki_dir, name), "w") as f:
            f.write(f"SECRET-{name}")
    for tool, body in (
        ("etcdctl", 'touch "${@: -1}"'),
        ("etcdutl", "true"),
    ):
        path = os.path.join(bin_dir, tool)
        with open(path, "w") as f:
            f.write(f"#!/bin/bash\n{body}\n")
        os.chmod(path, stat.S_IRWXU)
    return backup_dir, cert_dir, pki_dir, bin_dir


def _run(script_text, tmpdir, extra_env=None):
    path = os.path.join(tmpdir, "run.sh")
    with open(path, "w") as f:
        f.write(script_text)
    os.chmod(path, stat.S_IRWXU)
    env = {**os.environ, "NODE_NAME": "cp1", **(extra_env or {})}
    return subprocess.run([path], capture_output=True, text=True, env=env)


@pytest.mark.skipif(not shutil.which("gpg"), reason="gpg not installed")
def test_pki_archive_is_encrypted_and_restorable():
    with tempfile.TemporaryDirectory() as tmpdir:
        backup_dir, cert_dir, pki_dir, bin_dir = _fixture(tmpdir)
        home = os.path.join(tmpdir, "operator-gnupg")
        os.makedirs(home, mode=0o700)
        gpg = ["gpg", "--batch", "--homedir", home, "--pinentry-mode", "loopback", "--passphrase", ""]
        subprocess.run(gpg + ["--quick-gen-key", "dr-test", "rsa3072", "encrypt", "never"], check=True, capture_output=True)
        recipient = os.path.join(tmpdir, "recipient.asc")
        with open(recipient, "w") as f:
            f.write(subprocess.run(gpg + ["--armor", "--export", "dr-test"], check=True, capture_output=True, text=True).stdout)

        result = _run(_render(backup_dir, pki_dir, recipient, bin_dir, cert_dir), tmpdir)
        assert result.returncode == 0, result.stderr
        archives = [f for f in os.listdir(backup_dir) if f.startswith("cluster-pki-cp1-") and f.endswith(".tar.gpg")]
        assert len(archives) == 1
        archive = os.path.join(backup_dir, archives[0])
        assert stat.S_IMODE(os.stat(archive).st_mode) == 0o600
        with open(archive, "rb") as f:
            assert b"SECRET-" not in f.read(), "archive is not encrypted"

        out = os.path.join(tmpdir, "restored")
        os.makedirs(out)
        plain = subprocess.run(gpg + ["--decrypt", archive], check=True, capture_output=True).stdout
        subprocess.run(["tar", "-C", out, "-xf", "-"], input=plain, check=True)
        for name in ("ca.crt", "ca.key", "sa.key", "etcd/ca.key"):
            with open(os.path.join(out, name)) as f:
                assert f.read() == f"SECRET-{name}"


def test_pki_backup_fails_the_run_when_the_recipient_key_is_missing():
    with tempfile.TemporaryDirectory() as tmpdir:
        backup_dir, cert_dir, pki_dir, bin_dir = _fixture(tmpdir)
        script = _render(backup_dir, pki_dir, os.path.join(tmpdir, "missing.asc"), bin_dir, cert_dir)
        result = _run(script, tmpdir)
        assert result.returncode != 0
        assert "not readable" in result.stderr
        with open(os.path.join(backup_dir, ".etcd-backup-status-cp1")) as f:
            assert f.read().split()[1] == "0", "failure must be recorded for the backup KPI"


def test_pki_backup_is_skipped_when_disabled():
    with tempfile.TemporaryDirectory() as tmpdir:
        backup_dir, cert_dir, pki_dir, bin_dir = _fixture(tmpdir)
        result = _run(_render(backup_dir, pki_dir, "", bin_dir, cert_dir), tmpdir)
        assert result.returncode == 0, result.stderr
        assert not [f for f in os.listdir(backup_dir) if f.startswith("cluster-pki-")]
