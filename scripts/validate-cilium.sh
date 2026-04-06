#!/usr/bin/env bash
# scripts/validate-cilium.sh
# Post-installation validation for Isovalent Enterprise for Cilium.
# Provides clear pass/fail output for each check.
# Called by: make validate
#
# Author: Julio Garcia

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

HELM_NAMESPACE="${HELM_NAMESPACE:-kube-system}"
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

# Load .env
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

# ─── Cilium pods ──────────────────────────────────────────────────────────────
header "Cilium DaemonSet pods"

TOTAL_CILIUM=$(kubectl -n "${HELM_NAMESPACE}" get ds cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
READY_CILIUM=$(kubectl -n "${HELM_NAMESPACE}" get ds cilium -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)

if [[ "${TOTAL_CILIUM}" -gt 0 ]]; then
  if [[ "${READY_CILIUM}" -eq "${TOTAL_CILIUM}" ]]; then
    pass "Cilium DaemonSet: ${READY_CILIUM}/${TOTAL_CILIUM} pods ready"
  else
    fail "Cilium DaemonSet: ${READY_CILIUM}/${TOTAL_CILIUM} pods ready"
  fi
else
  fail "Cilium DaemonSet not found in ${HELM_NAMESPACE}"
fi

# ─── Cilium operator ──────────────────────────────────────────────────────────
header "Cilium operator"

OPERATOR_READY=$(kubectl -n "${HELM_NAMESPACE}" get deploy cilium-operator \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
OPERATOR_DESIRED=$(kubectl -n "${HELM_NAMESPACE}" get deploy cilium-operator \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)

if [[ "${OPERATOR_READY}" -gt 0 ]]; then
  pass "Cilium operator: ${OPERATOR_READY}/${OPERATOR_DESIRED} replicas ready"
else
  fail "Cilium operator: ${OPERATOR_READY}/${OPERATOR_DESIRED} replicas ready"
fi

# ─── Cilium status (from agent) ───────────────────────────────────────────────
header "Cilium agent status"

CILIUM_POD=$(kubectl -n "${HELM_NAMESPACE}" get pods -l k8s-app=cilium \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "${CILIUM_POD}" ]]; then
  echo "    Querying status from pod: ${CILIUM_POD}"
  if kubectl -n "${HELM_NAMESPACE}" exec "${CILIUM_POD}" -- cilium status --brief 2>/dev/null; then
    pass "Cilium agent status check completed"
  else
    warn "Could not retrieve cilium status — check pod logs"
  fi
else
  fail "No running Cilium pod found to query status"
fi

# ─── Hubble relay ─────────────────────────────────────────────────────────────
header "Hubble relay"

HUBBLE_RELAY_READY=$(kubectl -n "${HELM_NAMESPACE}" get deploy hubble-relay \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
HUBBLE_RELAY_DESIRED=$(kubectl -n "${HELM_NAMESPACE}" get deploy hubble-relay \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)

if [[ "${HUBBLE_RELAY_READY}" -gt 0 ]]; then
  pass "Hubble relay: ${HUBBLE_RELAY_READY}/${HUBBLE_RELAY_DESIRED} replicas ready"
else
  fail "Hubble relay: ${HUBBLE_RELAY_READY}/${HUBBLE_RELAY_DESIRED} replicas ready"
fi

# ─── Hubble UI ────────────────────────────────────────────────────────────────
header "Hubble UI"

HUBBLE_UI_READY=$(kubectl -n "${HELM_NAMESPACE}" get deploy hubble-ui \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
HUBBLE_UI_DESIRED=$(kubectl -n "${HELM_NAMESPACE}" get deploy hubble-ui \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)

if [[ "${HUBBLE_UI_READY}" -gt 0 ]]; then
  pass "Hubble UI: ${HUBBLE_UI_READY}/${HUBBLE_UI_DESIRED} replicas ready"
else
  fail "Hubble UI: ${HUBBLE_UI_READY}/${HUBBLE_UI_DESIRED} replicas ready"
fi

# ─── Node networking: all nodes have Cilium endpoint ─────────────────────────
header "Node coverage"

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ -n "${CILIUM_POD}" ]]; then
  ENDPOINT_COUNT=$(kubectl -n "${HELM_NAMESPACE}" exec "${CILIUM_POD}" -- \
    cilium endpoint list --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${ENDPOINT_COUNT}" -gt 0 ]]; then
    pass "Cilium endpoints active: ${ENDPOINT_COUNT} (across ${NODE_COUNT} nodes)"
  else
    warn "No Cilium endpoints found — may be expected on a fresh cluster with no workload pods"
  fi
else
  warn "Cannot check endpoint coverage — no running Cilium pod"
fi

# ─── kube-proxy replacement verification ─────────────────────────────────────
header "kube-proxy replacement"

if [[ -n "${CILIUM_POD}" ]]; then
  KPR_STATUS=$(kubectl -n "${HELM_NAMESPACE}" exec "${CILIUM_POD}" -- \
    cilium status 2>/dev/null | grep -i "KubeProxyReplacement" || echo "")
  if echo "${KPR_STATUS}" | grep -qi "True\|strict\|enabled"; then
    pass "kube-proxy replacement: active — ${KPR_STATUS}"
  else
    warn "kube-proxy replacement status unclear: ${KPR_STATUS:-not found in status output}"
  fi
else
  warn "Cannot verify kube-proxy replacement — no running Cilium pod"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────"
echo "  Validation summary: ${PASS} passed, ${WARN} warnings, ${FAIL} failed"
echo "────────────────────────────────────────────────────────"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
  echo "  One or more validation checks failed."
  echo "  See docs/runbooks/cilium-validate.md for troubleshooting guidance."
  exit 1
elif [[ "${WARN}" -gt 0 ]]; then
  echo "  Validation passed with warnings. Review warnings above."
  exit 0
else
  echo "  All validation checks passed."
  echo "  Run 'make hubble' to access the Hubble observability UI."
  exit 0
fi
