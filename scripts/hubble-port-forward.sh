#!/usr/bin/env bash
# scripts/hubble-port-forward.sh
# Port-forwards Hubble UI to localhost for local browser access.
# Called by: make hubble
#
# Usage:
#   bash scripts/hubble-port-forward.sh
#   make hubble
#
# Access Hubble UI at: http://localhost:12000
#
# Author: Julio Garcia

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

HELM_NAMESPACE="${HELM_NAMESPACE:-kube-system}"
LOCAL_PORT="${HUBBLE_LOCAL_PORT:-12000}"
HUBBLE_UI_SVC_PORT=80  # hubble-ui ClusterIP service listens on port 80

# Load .env if present (optional)
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

# Auto-detect KUBECONFIG
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "${HOME}/.kube/config" ]]; then
    export KUBECONFIG="${HOME}/.kube/config"
  fi
fi

echo "==> Starting Hubble UI port-forward..."
echo "    Namespace:  ${HELM_NAMESPACE}"
echo "    Service:    hubble-ui"
echo "    Local port: ${LOCAL_PORT}"
echo ""
echo "    Access Hubble UI at: http://localhost:${LOCAL_PORT}"
echo ""
echo "    Press Ctrl-C to stop the port-forward."
echo ""

# Verify Hubble UI service exists
if ! kubectl -n "${HELM_NAMESPACE}" get svc hubble-ui &>/dev/null; then
  echo "ERROR: hubble-ui service not found in ${HELM_NAMESPACE}."
  echo "       Verify Hubble UI is enabled: helm get values cilium -n ${HELM_NAMESPACE} | grep hubble"
  exit 1
fi

kubectl port-forward \
  --namespace "${HELM_NAMESPACE}" \
  service/hubble-ui \
  "${LOCAL_PORT}:${HUBBLE_UI_SVC_PORT}"
