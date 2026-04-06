#!/usr/bin/env bash
# scripts/install-cilium.sh
# Installs Isovalent Enterprise for Cilium via Helm.
# Sources .env for operator-supplied inputs.
#
# The Isovalent Helm repo (https://helm.isovalent.com) is publicly accessible.
# No credentials are required to add the repo or download the chart.
#
# Called by: make install
# Dry-run:   DRY_RUN=true bash scripts/install-cilium.sh
#            make dry-run
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
ISOVALENT_HELM_REPO="${ISOVALENT_HELM_REPO:-https://helm.isovalent.com}"
DRY_RUN="${DRY_RUN:-false}"

# ─── Load .env if present (optional) ─────────────────────────────────────────
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  echo "==> Loaded .env"
fi

# ─── Auto-detect KUBECONFIG ───────────────────────────────────────────────────
# Use KUBECONFIG from environment if set; otherwise fall back to the default
# kubectl location. The explicit file check is skipped when kubectl works
# without a file path (e.g., in-cluster or merged kubeconfig).
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "${HOME}/.kube/config" ]]; then
    export KUBECONFIG="${HOME}/.kube/config"
  fi
fi

# ─── Validate cluster access ──────────────────────────────────────────────────
echo ""
echo "==> Checking cluster access..."

if ! kubectl get nodes &>/dev/null; then
  echo "ERROR: Cannot reach cluster."
  if [[ -z "${KUBECONFIG:-}" ]]; then
    echo "       KUBECONFIG is not set and ~/.kube/config not found."
    echo "       Download kubeconfig from Omni:"
    echo "       https://bellyupdown.na-west-1.omni.siderolabs.io/clusters"
  else
    echo "       KUBECONFIG: ${KUBECONFIG}"
  fi
  exit 1
fi

CLUSTER_API_ENDPOINT="${CLUSTER_API_ENDPOINT:-20.120.8.75}"
HELM_CHART="${HELM_CHART:-isovalent/cilium}"

echo "    KUBECONFIG:           ${KUBECONFIG}"
echo "    CLUSTER_API_ENDPOINT: ${CLUSTER_API_ENDPOINT}"
echo "    HELM_CHART:           ${HELM_CHART}"
echo "    HELM_RELEASE:         ${HELM_RELEASE}"
echo "    HELM_NAMESPACE:       ${HELM_NAMESPACE}"
echo "    DRY_RUN:              ${DRY_RUN}"

# ─── Add / refresh Isovalent Helm repo ───────────────────────────────────────
echo ""
echo "==> Adding Isovalent Helm repo (public, no credentials required)..."
helm repo add isovalent "${ISOVALENT_HELM_REPO}" --force-update
helm repo update isovalent
echo "    Repo ready: isovalent → ${ISOVALENT_HELM_REPO}"

# ─── Resolve chart version ────────────────────────────────────────────────────
echo ""
if [[ -n "${ISOVALENT_VERSION:-}" ]]; then
  echo "==> Using pinned ISOVALENT_VERSION=${ISOVALENT_VERSION}"
else
  echo "==> ISOVALENT_VERSION not set — discovering latest stable from ${HELM_CHART}..."
  ISOVALENT_VERSION=$(
    helm search repo "${HELM_CHART}" --versions 2>/dev/null \
      | grep -v -E "dev|beta|alpha|9999|NAME" \
      | awk 'NR==1{print $2}'
  )
  if [[ -z "${ISOVALENT_VERSION}" ]]; then
    echo "ERROR: Could not determine a chart version for ${HELM_CHART}."
    echo "       Run: make discover-version"
    echo "       Then set ISOVALENT_VERSION in .env"
    exit 1
  fi
  echo "    Auto-discovered: ${ISOVALENT_VERSION}"
  echo "    To pin this version, add to .env:  ISOVALENT_VERSION=${ISOVALENT_VERSION}"
fi

# Verify the version exists in the repo
if ! helm search repo "${HELM_CHART}" --version "${ISOVALENT_VERSION}" 2>/dev/null | grep -q "${HELM_CHART}"; then
  echo ""
  echo "ERROR: Version ${ISOVALENT_VERSION} not found for ${HELM_CHART}."
  echo "       Available versions:"
  helm search repo "${HELM_CHART}" --versions 2>/dev/null \
    | grep -v -E "dev|beta|alpha|9999" | head -10
  exit 1
fi
echo "    Version confirmed: ${HELM_CHART}@${ISOVALENT_VERSION}"

# ─── Dry-run / template mode ──────────────────────────────────────────────────
if [[ "${DRY_RUN}" == "true" ]]; then
  echo ""
  echo "==> DRY RUN — rendering Helm templates (no changes applied to cluster)"
  echo ""
  helm template "${HELM_RELEASE}" "${HELM_CHART}" \
    --namespace "${HELM_NAMESPACE}" \
    --version "${ISOVALENT_VERSION}" \
    --values "${HELM_VALUES}" \
    --values "${HELM_VALUES_ENV}" \
    --set "k8sServiceHost=${CLUSTER_API_ENDPOINT}" \
    --set "k8sServicePort=6443"
  echo ""
  echo "==> Dry run complete. Re-run without DRY_RUN=true to install."
  exit 0
fi

# ─── Helm install ─────────────────────────────────────────────────────────────
echo ""
echo "==> Running helm upgrade --install..."
echo "    Chart:     ${HELM_CHART}@${ISOVALENT_VERSION}"
echo "    Release:   ${HELM_RELEASE}"
echo "    Namespace: ${HELM_NAMESPACE}"
echo "    Values:    values.yaml + values.azure-talos.yaml"
echo ""

helm upgrade --install "${HELM_RELEASE}" "${HELM_CHART}" \
  --namespace "${HELM_NAMESPACE}" \
  --create-namespace \
  --version "${ISOVALENT_VERSION}" \
  --values "${HELM_VALUES}" \
  --values "${HELM_VALUES_ENV}" \
  --set "k8sServiceHost=${CLUSTER_API_ENDPOINT}" \
  --set "k8sServicePort=6443" \
  --atomic \
  --timeout 10m \
  --wait

echo ""
echo "==> Isovalent Enterprise for Cilium installed successfully."
echo "    Chart:   ${HELM_CHART}@${ISOVALENT_VERSION}"
echo "    Release: helm status ${HELM_RELEASE} -n ${HELM_NAMESPACE}"
echo ""
echo "    Next: make validate"
