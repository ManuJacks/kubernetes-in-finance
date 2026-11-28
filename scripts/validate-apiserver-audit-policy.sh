#!/usr/bin/env bash
# Load the audit policy with the cluster's real kube-apiserver binary (Docker).
# Passes when the server gets past policy loading and stops at storage, as it
# must without etcd. Run before every policy change (CHG-2026-11-27).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
policy="${1:-$root/ansible/roles/apiserver-audit/files/audit-policy.yaml}"
version="${KUBE_VERSION:-v1.36.6}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cp "$policy" "$work/policy.yaml"
openssl genrsa -out "$work/sa.key" 2048 2>/dev/null
chmod 644 "$work/sa.key" "$work/policy.yaml"
out="$(timeout 90 docker run --rm -v "$work:/p:ro" "registry.k8s.io/kube-apiserver:$version" \
  kube-apiserver --audit-policy-file=/p/policy.yaml --audit-log-path=- \
  --etcd-servers=http://127.0.0.1:1 --service-account-issuer=https://validate.invalid \
  --service-account-key-file=/p/sa.key --service-account-signing-key-file=/p/sa.key \
  --service-cluster-ip-range=10.0.0.0/24 --cert-dir=/tmp 2>&1 || true)"
if grep -q 'loading audit policy file' <<<"$out"; then
  grep 'loading audit policy file' <<<"$out" >&2; echo "audit policy INVALID" >&2; exit 1
fi
if grep -q 'error creating storage factory' <<<"$out"; then
  echo "audit policy valid for kube-apiserver $version"; exit 0
fi
echo "unexpected kube-apiserver output; policy not proven:" >&2; tail -5 <<<"$out" >&2; exit 2
