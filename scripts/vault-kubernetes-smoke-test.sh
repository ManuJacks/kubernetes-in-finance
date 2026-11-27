#!/usr/bin/env bash
# Redaction-safe smoke test for Vault Kubernetes authentication.
set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/kubernetes-in-finance.conf}"
NAMESPACE="${VAULT_TEST_NAMESPACE:-debug-system}"
CA_FILE="${VAULT_INTERNAL_CA_FILE:-/usr/local/share/ca-certificates/kif-internal-root-ca.crt}"
VAULT_ADDR_VALUE="${VAULT_ADDR:-https://vault.kif.io:8200}"
VAULT_ROLE="${VAULT_KUBERNETES_ROLE:-prod-debug}"
APP_PATH="${VAULT_APP_PATH:-production-debug/application/smoke-test}"
DB_PATH="${VAULT_DB_PATH:-production-debug/database/smoke-test}"
NAME="vault-kubernetes-smoke-$(date +%s)"
CA_CONFIGMAP="${NAME}-ca"

die() { echo "ERROR: $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl is required"
[[ -r "$KUBECONFIG_PATH" ]] || die "kubeconfig is not readable: $KUBECONFIG_PATH"
[[ -r "$CA_FILE" ]] || die "internal CA is not readable: $CA_FILE"

cleanup() {
  status=$?
  if [[ "$status" -ne 0 ]] && kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$NAMESPACE" get pod "$NAME" >/dev/null 2>&1; then
    echo "Smoke test failed; pod output before cleanup:" >&2
    kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$NAMESPACE" logs "$NAME" >&2 || true
  fi
  kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$NAMESPACE" delete pod "$NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$NAMESPACE" delete configmap "$CA_CONFIGMAP" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Creating temporary CA ConfigMap and smoke-test pod..."
kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$NAMESPACE" create configmap "$CA_CONFIGMAP" \
  --from-file=ca.crt="$CA_FILE" >/dev/null

kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$NAMESPACE" create -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${NAME}
  labels:
    app.kubernetes.io/name: vault-kubernetes-smoke
spec:
  restartPolicy: Never
  serviceAccountName: prod-debug-sa
  automountServiceAccountToken: true
  containers:
    - name: test
      image: ghcr.io/manujacks/production-debug:0.2.0
      imagePullPolicy: IfNotPresent
      env:
        - name: VAULT_ROLE
          value: "${VAULT_ROLE}"
        - name: VAULT_ADDR_VALUE
          value: "${VAULT_ADDR_VALUE}"
        - name: APP_PATH
          value: "${APP_PATH}"
        - name: DB_PATH
          value: "${DB_PATH}"
      command: ["/bin/bash", "-c"]
      args:
        - |
          set -euo pipefail
          jwt="\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
          response="\$(curl --fail-with-body --silent --show-error --cacert /etc/kif-ca/ca.crt --request POST --data "\$(jq -n --arg jwt "\$jwt" --arg role "\$VAULT_ROLE" '{role:\$role,jwt:\$jwt}')" "\${VAULT_ADDR_VALUE}/v1/auth/kubernetes/login")"
          echo "\$response" | jq -e '.auth.client_token and .auth.lease_duration' >/dev/null
          echo "\$response" | jq '{authenticated: (.auth.client_token != null), lease_duration: .auth.lease_duration, policies: .auth.policies}'
          token="\$(echo "\$response" | jq -r '.auth.client_token')"
          app_status="\$(curl --silent --output /dev/null --write-out '%{http_code}' --cacert /etc/kif-ca/ca.crt --header "X-Vault-Token: \$token" "\${VAULT_ADDR_VALUE}/v1/secret/data/\${APP_PATH}")"
          db_status="\$(curl --silent --output /dev/null --write-out '%{http_code}' --cacert /etc/kif-ca/ca.crt --header "X-Vault-Token: \$token" "\${VAULT_ADDR_VALUE}/v1/secret/data/\${DB_PATH}")"
          echo "application_path_http_status=\$app_status"
          echo "database_path_http_status=\$db_status"
          test "\$app_status" = 200
          test "\$db_status" = 403
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 10001
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: kif-ca
          mountPath: /etc/kif-ca
          readOnly: true
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: kif-ca
      configMap:
        name: ${CA_CONFIGMAP}
    - name: tmp
      emptyDir: {}
EOF

for _ in {1..180}; do
  phase="$(kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$NAMESPACE" get pod "$NAME" -o jsonpath='{.status.phase}')"
  case "$phase" in
    Succeeded) break ;;
    Failed) echo "Smoke test pod failed" >&2; exit 1 ;;
  esac
  sleep 1
done
[[ "${phase:-}" == Succeeded ]] || { echo "Smoke test timed out" >&2; exit 1; }
kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$NAMESPACE" logs "$NAME"
echo "Vault Kubernetes smoke test passed; temporary resources will be removed."
