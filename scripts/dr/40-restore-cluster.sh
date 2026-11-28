#!/usr/bin/env bash
# DR phase 3: Kubernetes from the restored state (DR plan phase 3;
# docs/runbooks/etcd-backup-restore.md section 7).
#
#   scripts/dr/40-restore-cluster.sh [--execute]
#
# The operator decrypts the newest cluster PKI archive into memory (gpg
# passphrase; the private key never reaches a node). 17-restore-control-plane
# then refuses unless that CA matches the fingerprint in before.json, restores
# etcd on tf-ha-control1 and runs kubeadm init; the others join; what kubeadm
# does not keep (audit logging, backups) and monitoring are re-applied.
# shellcheck source=scripts/dr/lib.sh
. "$(dirname "$0")/lib.sh"

RUN="$(dr_run_dir)"
CA_FPR="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["identity"]["cluster_ca_pubkey_sha256"])' "$RUN/before.json")"
SHM=/dev/shm/kif-dr
PKI_TAR="$SHM/cluster-pki.tar"

dr_phase 3-cluster start
dr_run install -d -m 0700 "$SHM"
# Newest archive from any control plane: they hold the same PKI.
dr_run bash -c "sudo sh -c 'ls -t /srv/k8s-etcd-backups/cluster-pki-*.tar.gpg | head -1 | xargs cat' | gpg --decrypt >'$PKI_TAR'"
dr_playbook 17-restore-control-plane.yml -e "dr_pki_tarball=$PKI_TAR" -e "dr_expected_ca_pubkey_sha256=$CA_FPR"
dr_run shred -u "$PKI_TAR"
dr_playbook 07-join-control-planes.yml
dr_playbook 08-join-workers.yml
dr_run kubectl wait --for=condition=Ready nodes --all --timeout=15m
# T9: add-ons come back from etcd; re-run 06-cilium.yml only if this times out.
dr_run kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
dr_playbook 15-apiserver-audit.yml
dr_playbook 10-etcd-backup.yml
dr_playbook 13-monitoring.yml
dr_phase 3-cluster end
