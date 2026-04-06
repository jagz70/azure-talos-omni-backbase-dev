#!/usr/bin/env bash
# scripts/install-cilium.sh
# Installs Isovalent Enterprise for Cilium via Helm.
# Sources .env for operator-supplied inputs.
# Called by: make install
#
# Author: Julio Garcia

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
HELM_VALUES="${REPO_ROOT}/helm/isovalent-enterprise/values.yaml"
HELM_VALUES_ENV="${REPO_ROOT}/helm/isovalent-enterprise/values.azure-talos.yaml"

HELM_NAMESPACE="${HELM_NAMESPACE:-kube-system}"
HELM_RELEASE="${HELM_RELEASE:-cilium}"

# ─── Load .env ────────────────────────────────────────────────────────────────
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  echo "==> Loaded .env"
else
  echo "ERROR: .env not found at ${ENV_FILE}"
  echo "       Copy .env.example to .env and populate required values."
  exit 1
fi

# ─── Validate required inputs ─────────────────────────────────────────────────
echo "==> Validating required inputs..."

require_var() {
  local var_name="$1"
  local hint="${2:-}"
  if [[ -z "${!var_name:-}" ]]; then
    echo "ERROR: ${var_name} is not set in .env"
    [[ -n "${hint}" ]] && echo "       ${hint}"
    exit 1
  fi
}

require_var KUBECONFIG        "Download kubeconfig from Omni: https://bellyupdown.na-west-1.omni.siderolabs.io/clusters"
require_var CLUSTER_API_ENDPOINT "Set to the load balancer IP (20.120.8.75)"
require_var ISOVALENT_HELM_REPO  "Set to the Isovalent Helm repo URL. Confirm from your Isovalent customer portal."
require_var ISOVALENT_VERSION    "Set to the exact chart version for Isovalent Enterprise v25.11. Confirm from your Isovalent customer portal."

echo "    KUBECONFIG:              ${KUBECONFIG}"
echo "    CLUSTER_API_ENDPOINT:    ${CLUSTER_API_ENDPOINT}"
echo "    ISOVALENT_HELM_REPO:     ${ISOVALENT_HELM_REPO}"
echo "    ISOVALENT_VERSION:       ${ISOVALENT_VERSION}"
echo "    HELM_RELEASE:            ${HELM_RELEASE}"
echo "    HELM_NAMESPACE:          ${HELM_NAMESPACE}"

# ─── Add Isovalent Helm repo ──────────────────────────────────────────────────
echo ""
echo "==> Adding Isovalent Helm repository..."

if [[ -n "${ISOVALENT_HELM_USERNAME:-}" ]] && [[ -n "${ISOVALENT_HELM_TOKEN:-}" ]]; then
  echo "    Using authenticated access (credentials from .env)"
  helm repo add isovalent "${ISOVALENT_HELM_REPO}" \
    --username "${ISOVALENT_HELM_USERNAME}" \
    --password "${ISOVALENT_HELM_TOKEN}" \
    --force-update
else
  echo "    No credentials set — attempting unauthenticated repo access"
  echo "    If this fails, set ISOVALENT_HELM_USERNAME and ISOVALENT_HELM_TOKEN in .env"
  helm repo add isovalent "${ISOVALENT_HELM_REPO}" --force-update
fi

helm repo update isovalent
echo "    Helm repo updated."

# ─── Verify chart version exists ─────────────────────────────────────────────
echo ""
echo "==> Verifying chart version ${ISOVALENT_VERSION} is available..."
if ! helm search repo isovalent/cilium --version "${ISOVALENT_VERSION}" | grep -q "isovalent/cilium"; then
  echo "ERROR: Chart version ${ISOVALENT_VERSION} not found in isovalent repo."
  echo "       Run: helm search repo isovalent/cilium --versions"
  echo "       Then set the correct version in ISOVALENT_VERSION in .env"
  exit 1
fi
echo "    Chart version ${ISOVALENT_VERSION}: found."

# ─── Create image pull secret (if credentials are provided) ───────────────────
if [[ -n "${ISOVALENT_HELM_USERNAME:-}" ]] && [[ -n "${ISOVALENT_HELM_TOKEN:-}" ]]; then
  echo ""
  echo "==> Creating imagePullSecret 'isovalent-pull-secret' in ${HELM_NAMESPACE}..."
  # Confirm the registry URL with your Isovalent customer portal.
  # This is a common pattern for enterprise Helm charts — adjust if Isovalent uses a different registry.
  ISOVALENT_REGISTRY="${ISOVALENT_REGISTRY:-registry.isovalent.com}"
  kubectl create secret docker-registry isovalent-pull-secret \
    --namespace "${HELM_NAMESPACE}" \
    --docker-server="${ISOVALENT_REGISTRY}" \
    --docker-username="${ISOVALENT_HELM_USERNAME}" \
    --docker-password="${ISOVALENT_HELM_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "    imagePullSecret created."
fi

# ─── Create license secret (if license key is provided) ───────────────────────
if [[ -n "${ISOVALENT_LICENSE_KEY:-}" ]]; then
  echo ""
  echo "==> Creating license secret 'isovalent-license' in ${HELM_NAMESPACE}..."
  kubectl create secret generic isovalent-license \
    --namespace "${HELM_NAMESPACE}" \
    --from-literal=license="${ISOVALENT_LICENSE_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "    License secret created."
fi

# ─── Helm install ─────────────────────────────────────────────────────────────
echo ""
echo "==> Running helm upgrade --install for ${HELM_RELEASE}..."
echo "    Chart:     isovalent/cilium @ ${ISOVALENT_VERSION}"
echo "    Namespace: ${HELM_NAMESPACE}"
echo "    Values:    ${HELM_VALUES}"
echo "               ${HELM_VALUES_ENV}"
echo ""

helm upgrade --install "${HELM_RELEASE}" isovalent/cilium \
  --namespace "${HELM_NAMESPACE}" \
  --create-namespace \
  --version "${ISOVALENT_VERSION}" \
  --values "${HELM_VALUES}" \
  --values "${HELM_VALUES_ENV}" \
  --atomic \
  --timeout 10m \
  --wait

echo ""
echo "==> Isovalent Enterprise for Cilium installed successfully."
echo ""
echo "    Next: run 'make validate' to confirm the installation is healthy."
