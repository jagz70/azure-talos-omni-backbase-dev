#!/usr/bin/env bash
# scripts/preflight.sh
# Pre-installation checks for Isovalent Enterprise for Cilium.
# Verifies tooling, cluster access, and preconditions before install.
#
# Usage: bash scripts/preflight.sh (or: make preflight)
# Author: Julio Garcia

set -euo pipefail

PASS=0
FAIL=0
WARN=0

green()  { echo -e "\033[32m  PASS\033[0m  $*"; }
red()    { echo -e "\033[31m  FAIL\033[0m  $*"; }
yellow() { echo -e "\033[33m  WARN\033[0m  $*"; }
header() { echo -e "\n\033[1m==> $*\033[0m"; }

pass() { green "$*";  PASS=$((PASS+1)); }
fail() { red "$*";    FAIL=$((FAIL+1)); }
warn() { yellow "$*"; WARN=$((WARN+1)); }

# ─── Load environment ─────────────────────────────────────────────────────────
header "Environment"

ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  pass ".env loaded from ${ENV_FILE}"
else
  fail ".env not found. Copy .env.example to .env and populate it."
  echo "       Aborting — .env is required."
  exit 1
fi

# ─── Required variables ───────────────────────────────────────────────────────
header "Required variables"

check_var() {
  local var_name="$1"
  local var_value="${!var_name:-}"
  if [[ -z "${var_value}" ]]; then
    fail "${var_name} is not set in .env"
  else
    pass "${var_name} = ${var_value}"
  fi
}

check_var KUBECONFIG
check_var CLUSTER_API_ENDPOINT
check_var ISOVALENT_HELM_REPO

if [[ -z "${ISOVALENT_VERSION:-}" ]]; then
  warn "ISOVALENT_VERSION is not set. You must set this before running make install."
else
  pass "ISOVALENT_VERSION = ${ISOVALENT_VERSION}"
fi

# ─── Tool checks ──────────────────────────────────────────────────────────────
header "Required tools"

check_tool() {
  local tool="$1"
  local min_note="${2:-}"
  if command -v "${tool}" &>/dev/null; then
    local version
    version=$("${tool}" version --client --short 2>/dev/null \
      || "${tool}" version 2>/dev/null | head -1 \
      || echo "(version unknown)")
    pass "${tool} found: ${version}"
  else
    fail "${tool} not found in PATH${min_note:+ — ${min_note}}"
  fi
}

check_tool kubectl
check_tool helm   "helm >= 3.12 required"
check_tool az

# ─── kubeconfig ───────────────────────────────────────────────────────────────
header "kubeconfig"

if [[ ! -f "${KUBECONFIG}" ]]; then
  fail "kubeconfig not found at: ${KUBECONFIG}"
  fail "Download from Omni: https://bellyupdown.na-west-1.omni.siderolabs.io/clusters"
else
  pass "kubeconfig file exists: ${KUBECONFIG}"
fi

# ─── Cluster connectivity ─────────────────────────────────────────────────────
header "Cluster connectivity"

if kubectl cluster-info &>/dev/null; then
  CLUSTER_INFO=$(kubectl cluster-info 2>/dev/null | head -1)
  pass "Cluster reachable: ${CLUSTER_INFO}"
else
  fail "Cannot reach cluster. Check KUBECONFIG and VPN/network access."
fi

# ─── Node readiness ───────────────────────────────────────────────────────────
header "Node readiness"

TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready " | wc -l | tr -d ' ')
CP_NODES=$(kubectl get nodes --no-headers -l node-role.kubernetes.io/control-plane 2>/dev/null | wc -l | tr -d ' ')
CP_NOT_READY=$(kubectl get nodes --no-headers -l node-role.kubernetes.io/control-plane 2>/dev/null | grep -v " Ready " | wc -l | tr -d ' ')

if [[ "${TOTAL_NODES}" -gt 0 ]]; then
  pass "Total nodes: ${TOTAL_NODES}"
else
  fail "No nodes found. Cluster may not be bootstrapped yet."
fi

if [[ "${CP_NOT_READY}" -eq 0 ]] && [[ "${CP_NODES}" -gt 0 ]]; then
  pass "Control plane nodes ready: ${CP_NODES}/${CP_NODES}"
else
  fail "Control plane nodes not all ready: ${CP_NODES} total, ${CP_NOT_READY} not ready"
  fail "Do not proceed — fix control plane first."
fi

if [[ "${NOT_READY}" -gt 0 ]]; then
  warn "${NOT_READY} node(s) not Ready. Workers may still be joining — acceptable if control plane is healthy."
fi

# ─── Existing CNI check ───────────────────────────────────────────────────────
header "Existing CNI"

EXISTING_CILIUM=$(kubectl -n kube-system get ds cilium --no-headers 2>/dev/null | wc -l | tr -d ' ')
EXISTING_FLANNEL=$(kubectl -n kube-system get ds kube-flannel --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "${EXISTING_CILIUM}" -gt 0 ]]; then
  warn "Cilium DaemonSet already exists in kube-system. If this is a reinstall, use 'make upgrade' instead."
else
  pass "No existing Cilium DaemonSet found"
fi

if [[ "${EXISTING_FLANNEL}" -gt 0 ]]; then
  fail "Flannel CNI is running. Cilium cannot be installed alongside Flannel."
  fail "Migration required. Follow: docs/runbooks/cni-migration-flannel-to-cilium.md"
  fail "Steps: (1) Set Omni cluster CNI to 'none', (2) delete Flannel, (3) delete kube-proxy, (4) re-run make install"
else
  pass "Flannel not found — CNI slot is clear for Cilium"
fi

# ─── kube-proxy check ────────────────────────────────────────────────────────
header "kube-proxy"

KUBE_PROXY=$(kubectl -n kube-system get ds kube-proxy --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "${KUBE_PROXY}" -gt 0 ]]; then
  fail "kube-proxy DaemonSet is running. Must be removed before Cilium kube-proxy replacement install."
  fail "Migration required. See: docs/runbooks/cni-migration-flannel-to-cilium.md"
  fail "kubectl -n kube-system delete ds kube-proxy"
else
  pass "kube-proxy not running (correct for Cilium kube-proxy replacement)"
fi

# ─── Helm repo check ──────────────────────────────────────────────────────────
header "Helm repository"

if helm repo list 2>/dev/null | grep -q "isovalent"; then
  pass "Isovalent Helm repo already added"
else
  warn "Isovalent Helm repo not yet added. Run 'make helm-repo-add' before install."
fi

# ─── Kubernetes version compatibility ────────────────────────────────────────
header "Kubernetes version"

K8S_VERSION=$(kubectl version --short 2>/dev/null | grep "Server Version" | awk '{print $3}' || \
              kubectl version 2>/dev/null | grep "Server Version" | grep -o 'v[0-9.]*')
if [[ -n "${K8S_VERSION}" ]]; then
  pass "Kubernetes server version: ${K8S_VERSION}"
  # Warn if 1.33+ — cilium-enterprise 1.17.x is not compatible
  MINOR=$(echo "${K8S_VERSION}" | cut -d. -f2)
  if [[ "${MINOR}" -ge 33 ]]; then
    # Check if HELM_CHART is the old cilium-enterprise
    CONFIGURED_CHART="${HELM_CHART:-isovalent/cilium}"
    if echo "${CONFIGURED_CHART}" | grep -q "cilium-enterprise"; then
      warn "k8s ${K8S_VERSION}: isovalent/cilium-enterprise (1.17.x) may not support this version."
      warn "Recommend: use HELM_CHART=isovalent/cilium (1.18.x) in .env for k8s 1.33+"
    else
      pass "HELM_CHART=${CONFIGURED_CHART} — compatible with k8s ${K8S_VERSION}"
    fi
  fi
else
  warn "Could not determine Kubernetes server version"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────"
echo "  Preflight summary: ${PASS} passed, ${WARN} warnings, ${FAIL} failed"
echo "────────────────────────────────────────────────────────"

if [[ "${FAIL}" -gt 0 ]]; then
  echo ""
  echo "  One or more checks failed. Resolve failures before running make install."
  exit 1
elif [[ "${WARN}" -gt 0 ]]; then
  echo ""
  echo "  Warnings present. Review before proceeding."
  exit 0
else
  echo ""
  echo "  All checks passed. Cluster is ready for Cilium installation."
  exit 0
fi
