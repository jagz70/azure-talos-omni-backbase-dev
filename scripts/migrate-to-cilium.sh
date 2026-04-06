#!/usr/bin/env bash
# scripts/migrate-to-cilium.sh
# Migrates the cluster from Flannel CNI + kube-proxy to Isovalent Enterprise for Cilium.
#
# What this script does:
#   1. Validates prerequisites (cluster reachable, no existing Cilium)
#   2. Removes Flannel DaemonSet and associated resources
#   3. Removes kube-proxy DaemonSet
#   4. Verifies Omni does not reconcile them back (30-second watch)
#   5. Installs Isovalent Enterprise for Cilium via Helm
#   6. Restarts CoreDNS to get Cilium-managed networking
#   7. Validates the installation
#
# Called by: make migrate-to-cilium
# Author: Julio Garcia

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

# ─── Load .env ────────────────────────────────────────────────────────────────
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

green()  { echo -e "\033[32m[OK]\033[0m  $*"; }
red()    { echo -e "\033[31m[FAIL]\033[0m $*"; }
yellow() { echo -e "\033[33m[WARN]\033[0m $*"; }
header() { echo -e "\n\033[1m══ $* ══\033[0m"; }
info()   { echo -e "    $*"; }

# ─── Pre-migration checks ─────────────────────────────────────────────────────
header "Pre-migration validation"

if [[ -z "${KUBECONFIG:-}" ]] || [[ ! -f "${KUBECONFIG}" ]]; then
  red "KUBECONFIG not set or file not found. Set KUBECONFIG in .env."
  exit 1
fi
green "KUBECONFIG: ${KUBECONFIG}"

if ! kubectl get nodes &>/dev/null; then
  red "Cannot reach cluster. Check KUBECONFIG and network."
  exit 1
fi
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
CP_READY=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | grep " Ready " | wc -l | tr -d ' ')
green "Cluster reachable — ${NODE_COUNT} nodes, ${CP_READY} control plane Ready"

# Abort if Cilium is already installed
if kubectl -n kube-system get ds cilium &>/dev/null 2>&1; then
  red "Cilium DaemonSet already exists. Use 'make upgrade' instead of migrate."
  exit 1
fi
green "No existing Cilium installation"

# Check Flannel and kube-proxy state
FLANNEL_EXISTS=$(kubectl -n kube-system get ds kube-flannel --no-headers 2>/dev/null | wc -l | tr -d ' ')
KPROXY_EXISTS=$(kubectl -n kube-system get ds kube-proxy --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "${FLANNEL_EXISTS}" -eq 0 ]] && [[ "${KPROXY_EXISTS}" -eq 0 ]]; then
  yellow "Neither Flannel nor kube-proxy found. Cluster may already be clean."
  yellow "Proceeding directly to Cilium install."
elif [[ "${FLANNEL_EXISTS}" -gt 0 ]]; then
  green "Flannel DaemonSet found — will be removed"
fi

if [[ "${KPROXY_EXISTS}" -gt 0 ]]; then
  green "kube-proxy DaemonSet found — will be removed"
fi

echo ""
echo "  This script will:"
echo "    1. Remove Flannel (if present)"
echo "    2. Remove kube-proxy (if present)"
echo "    3. Verify Omni does not reconcile them back (30s check)"
echo "    4. Install Isovalent Enterprise for Cilium via Helm"
echo "    5. Restart CoreDNS"
echo "    6. Validate the installation"
echo ""
echo "  Expected pod networking disruption: ~60-120 seconds"
echo "  No existing production workloads will be permanently affected."
echo ""
read -rp "  Proceed with migration? [y/N] " CONFIRM
if [[ "${CONFIRM,,}" != "y" ]]; then
  echo "  Aborted."
  exit 0
fi

# ─── Step 1: Remove Flannel ───────────────────────────────────────────────────
header "Step 1/6 — Remove Flannel"

if [[ "${FLANNEL_EXISTS}" -gt 0 ]]; then
  info "Deleting Flannel DaemonSet..."
  kubectl -n kube-system delete ds kube-flannel --timeout=60s

  info "Deleting Flannel ConfigMap..."
  kubectl -n kube-system delete cm kube-flannel-cfg 2>/dev/null || true

  info "Removing Flannel RBAC resources..."
  kubectl delete clusterrolebinding flannel 2>/dev/null || true
  kubectl delete clusterrole flannel 2>/dev/null || true
  kubectl -n kube-system delete serviceaccount flannel 2>/dev/null || true

  # Clean up node annotations left by Flannel (non-blocking)
  for NODE in $(kubectl get nodes -o name 2>/dev/null); do
    kubectl annotate "${NODE}" \
      flannel.alpha.coreos.com/backend-data- \
      flannel.alpha.coreos.com/backend-type- \
      flannel.alpha.coreos.com/kube-subnet-manager- \
      flannel.alpha.coreos.com/public-ip- 2>/dev/null || true
  done

  green "Flannel removed"
else
  info "Flannel not present — skipped"
fi

# ─── Step 2: Remove kube-proxy ────────────────────────────────────────────────
header "Step 2/6 — Remove kube-proxy"

if [[ "${KPROXY_EXISTS}" -gt 0 ]]; then
  info "Deleting kube-proxy DaemonSet..."
  kubectl -n kube-system delete ds kube-proxy --timeout=60s

  info "Deleting kube-proxy ConfigMap..."
  kubectl -n kube-system delete cm kube-proxy 2>/dev/null || true

  green "kube-proxy removed"
else
  info "kube-proxy not present — skipped"
fi

# ─── Step 3: Verify Omni does not reconcile them back ────────────────────────
header "Step 3/6 — Verify Omni non-reconciliation (30s)"

info "Watching for 30 seconds to confirm Omni does not recreate Flannel or kube-proxy..."
info "Evidence: no Omni labels on DaemonSets, no ownerReferences, bootstrap complete."
sleep 30

FLANNEL_BACK=$(kubectl -n kube-system get ds kube-flannel --no-headers 2>/dev/null | wc -l | tr -d ' ')
KPROXY_BACK=$(kubectl -n kube-system get ds kube-proxy --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "${FLANNEL_BACK}" -gt 0 ]]; then
  red "Flannel was recreated by Omni after deletion."
  red "Manual Omni action required: disable Flannel in Omni cluster CNI configuration."
  red "See docs/runbooks/cni-migration-flannel-to-cilium.md — Step 1."
  exit 1
fi
if [[ "${KPROXY_BACK}" -gt 0 ]]; then
  red "kube-proxy was recreated by Omni after deletion."
  red "This may happen if Omni is reconciling Kubernetes upgrade manifests."
  red "Re-run this script after a few minutes, or proceed and re-run after install."
  exit 1
fi
green "Confirmed: Omni did not reconcile Flannel or kube-proxy back"

# ─── Step 4: Install Cilium ───────────────────────────────────────────────────
header "Step 4/6 — Install Isovalent Enterprise for Cilium"
bash "${SCRIPT_DIR}/install-cilium.sh"

# ─── Step 5: Restart CoreDNS ──────────────────────────────────────────────────
header "Step 5/6 — Restart CoreDNS"

info "Rolling restart CoreDNS to get Cilium-managed networking..."
kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout status deployment/coredns -n kube-system --timeout=3m
green "CoreDNS restarted"

# ─── Step 6: Validate ─────────────────────────────────────────────────────────
header "Step 6/6 — Validate"
bash "${SCRIPT_DIR}/validate-cilium.sh"

echo ""
green "Migration complete."
echo ""
echo "  Run: make hubble   → http://localhost:12000"
echo "  Run: make validate → re-run validation at any time"
