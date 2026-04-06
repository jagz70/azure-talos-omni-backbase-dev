#!/usr/bin/env bash
# scripts/migrate-to-cilium.sh
# Dual-overlay CNI migration: Flannel → Isovalent Enterprise for Cilium
#
# Based on the official Cilium migration documentation:
# https://docs.cilium.io/en/latest/installation/k8s-install-migration/
#
# When Flannel is present (normal path): dual-overlay migration
#   Phase 1 — Install Cilium as secondary CNI alongside Flannel
#     Cilium overlay: VXLAN port 8473, pod CIDR 10.245.0.0/16
#     Flannel overlay: VXLAN port 8472, pod CIDR 10.244.0.0/16
#     kube-proxy replacement (eBPF) is active immediately on all nodes.
#   Phase 2 — Per-node migration: workers first, then control plane
#     cordon → drain → label → restart Cilium pod → uncordon
#     Labeled nodes use Cilium CNI via CiliumNodeConfig.
#   Phase 3 — Finalize
#     Upgrade Cilium to primary CNI mode. Remove Flannel. Validate.
#
# When Flannel is absent (cluster in intermediate state): clean install
#   Installs Cilium directly using k8sServiceHost=10.0.1.4 (internal CP
#   node IP). The Azure external LB (20.120.8.75) is blocked by Azure
#   hairpin restrictions from within the same VNet and must not be used.
#
# Called by: make migrate-to-cilium
# Author: Julio Garcia

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

HELM_VALUES="${REPO_ROOT}/helm/isovalent-enterprise/values.yaml"
HELM_VALUES_ENV="${REPO_ROOT}/helm/isovalent-enterprise/values.azure-talos.yaml"
HELM_VALUES_MIGRATION="${REPO_ROOT}/helm/isovalent-enterprise/values.migration.yaml"
HELM_VALUES_FINAL="${REPO_ROOT}/helm/isovalent-enterprise/values.final.yaml"

HELM_NAMESPACE="${HELM_NAMESPACE:-kube-system}"
HELM_RELEASE="${HELM_RELEASE:-cilium}"
HELM_CHART="${HELM_CHART:-isovalent/cilium}"
ISOVALENT_HELM_REPO="${ISOVALENT_HELM_REPO:-https://helm.isovalent.com}"
ISOVALENT_VERSION="${ISOVALENT_VERSION:-}"

# ─── Load .env if present (optional) ─────────────────────────────────────────
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

# ─── Auto-detect KUBECONFIG ───────────────────────────────────────────────────
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "${HOME}/.kube/config" ]]; then
    export KUBECONFIG="${HOME}/.kube/config"
  fi
fi

# ─── Output helpers ───────────────────────────────────────────────────────────
green()  { echo -e "\033[32m[OK]\033[0m  $*"; }
red()    { echo -e "\033[31m[FAIL]\033[0m $*"; }
yellow() { echo -e "\033[33m[WARN]\033[0m $*"; }
header() { echo -e "\n\033[1;36m══ $* ══\033[0m"; }
info()   { echo -e "    $*"; }
die()    { red "$*"; exit 1; }

# ─── wait_for_cilium_pod ──────────────────────────────────────────────────────
wait_for_cilium_pod() {
  local NODE="$1"
  local DEADLINE=$((SECONDS + 180))
  info "Waiting for Cilium pod Ready on ${NODE}..."
  while [[ $SECONDS -lt $DEADLINE ]]; do
    STATUS=$(kubectl -n "${HELM_NAMESPACE}" get pods \
      --field-selector "spec.nodeName=${NODE}" \
      -l k8s-app=cilium \
      -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' \
      2>/dev/null || echo "")
    if [[ "${STATUS}" == "True" ]]; then
      green "  Cilium pod ready on ${NODE}"
      return 0
    fi
    sleep 5
  done
  red "Cilium pod did not become Ready on ${NODE} within 3 minutes"
  kubectl -n "${HELM_NAMESPACE}" describe pods \
    --field-selector "spec.nodeName=${NODE}" \
    -l k8s-app=cilium 2>&1 | tail -20 || true
  return 1
}

# ─── migrate_node ─────────────────────────────────────────────────────────────
migrate_node() {
  local NODE="$1"
  local IDX="$2"
  local TOTAL="$3"

  header "Phase 2 — Node ${IDX}/${TOTAL}: ${NODE}"

  # Idempotent: skip if already migrated
  CURRENT_LABEL=$(kubectl get node "${NODE}" \
    -o jsonpath='{.metadata.labels.io\.cilium\.migration/cilium-default}' \
    2>/dev/null || echo "")
  if [[ "${CURRENT_LABEL}" == "true" ]]; then
    yellow "${NODE}: already labeled — verifying Cilium pod"
    wait_for_cilium_pod "${NODE}"
    info "${NODE}: already migrated"
    return 0
  fi

  # Cordon
  info "Cordoning ${NODE}..."
  kubectl cordon "${NODE}"

  # Drain (DaemonSet pods stay; --force removes unmanaged pods)
  info "Draining ${NODE}..."
  kubectl drain "${NODE}" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --timeout=5m \
    --force \
    2>&1 | grep -v "^Warning:" || true

  # Label — CiliumNodeConfig applies, makes Cilium active CNI on this node
  info "Labeling ${NODE} for Cilium CNI activation..."
  kubectl label node "${NODE}" --overwrite "io.cilium.migration/cilium-default=true"

  # Restart Cilium pod on this node — triggers writing 05-cilium.conflist
  info "Restarting Cilium pod on ${NODE}..."
  kubectl -n "${HELM_NAMESPACE}" delete pod \
    --field-selector "spec.nodeName=${NODE}" \
    -l k8s-app=cilium \
    --ignore-not-found \
    --wait=false 2>/dev/null || true

  # Wait for Cilium pod ready
  wait_for_cilium_pod "${NODE}"

  # Uncordon — new pods scheduled here receive IPs from 10.245.0.0/16
  info "Uncordoning ${NODE}..."
  kubectl uncordon "${NODE}"

  green "${NODE}: migrated to Cilium CNI (new pod IPs: 10.245.0.0/16)"
}

# ─── remove_flannel ───────────────────────────────────────────────────────────
remove_flannel() {
  FLANNEL_NOW=$(kubectl -n "${HELM_NAMESPACE}" get ds kube-flannel \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${FLANNEL_NOW}" -gt 0 ]]; then
    header "Remove Flannel"
    kubectl -n "${HELM_NAMESPACE}" delete ds kube-flannel --timeout=60s
    kubectl -n "${HELM_NAMESPACE}" delete cm kube-flannel-cfg 2>/dev/null || true
    kubectl delete clusterrolebinding flannel 2>/dev/null || true
    kubectl delete clusterrole flannel 2>/dev/null || true
    kubectl -n "${HELM_NAMESPACE}" delete serviceaccount flannel 2>/dev/null || true
    for NODE in $(kubectl get nodes -o name 2>/dev/null); do
      kubectl annotate "${NODE}" \
        flannel.alpha.coreos.com/backend-data- \
        flannel.alpha.coreos.com/backend-type- \
        flannel.alpha.coreos.com/kube-subnet-manager- \
        flannel.alpha.coreos.com/public-ip- 2>/dev/null || true
    done
    green "Flannel removed"
  else
    info "Flannel already absent"
  fi
}

# ─── restart_coredns ─────────────────────────────────────────────────────────
restart_coredns() {
  header "Restart CoreDNS"
  kubectl rollout restart deployment/coredns -n "${HELM_NAMESPACE}"
  kubectl rollout status deployment/coredns -n "${HELM_NAMESPACE}" --timeout=3m
  green "CoreDNS restarted"
}

# ─── run_dual_overlay_migration ───────────────────────────────────────────────
run_dual_overlay_migration() {
  # ── Phase 1: Install Cilium in secondary/migration mode ──────────────────
  header "Phase 1/3 — Install Cilium in migration/secondary mode"
  info "Chart:   ${HELM_CHART}@${ISOVALENT_VERSION}"
  info "Mode:    secondary (dual-overlay alongside Flannel)"
  info "CIDR:    10.245.0.0/16 (distinct from Flannel: 10.244.0.0/16)"
  info "Tunnel:  VXLAN port 8473 (distinct from Flannel: 8472)"
  echo ""

  helm upgrade --install "${HELM_RELEASE}" "${HELM_CHART}" \
    --namespace "${HELM_NAMESPACE}" \
    --create-namespace \
    --version "${ISOVALENT_VERSION}" \
    --values "${HELM_VALUES}" \
    --values "${HELM_VALUES_ENV}" \
    --values "${HELM_VALUES_MIGRATION}" \
    --wait \
    --timeout 12m

  CILIUM_DESIRED=$(kubectl -n "${HELM_NAMESPACE}" get ds cilium \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
  CILIUM_READY=$(kubectl -n "${HELM_NAMESPACE}" get ds cilium \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
  green "Cilium DaemonSet: ${CILIUM_READY}/${CILIUM_DESIRED} pods ready (standby — Flannel still active)"

  # ── Phase 1b: Apply CiliumNodeConfig ─────────────────────────────────────
  header "Phase 1b — Apply CiliumNodeConfig"
  kubectl apply --server-side -f - <<'NODECONFIG'
apiVersion: cilium.io/v2
kind: CiliumNodeConfig
metadata:
  namespace: kube-system
  name: cilium-default
spec:
  nodeSelector:
    matchLabels:
      io.cilium.migration/cilium-default: "true"
  defaults:
    write-cni-conf-when-ready: /host/etc/cni/net.d/05-cilium.conflist
    custom-cni-conf: "false"
    cni-chaining-mode: "none"
    cni-exclusive: "true"
NODECONFIG
  green "CiliumNodeConfig applied — nodes opt in via label io.cilium.migration/cilium-default=true"

  # ── Phase 2: Per-node migration ───────────────────────────────────────────
  header "Phase 2/3 — Per-node migration (workers first, then control plane)"

  mapfile -t WORKER_NODES < <(kubectl get nodes \
    -l '!node-role.kubernetes.io/control-plane' \
    --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
  mapfile -t CP_NODES < <(kubectl get nodes \
    -l node-role.kubernetes.io/control-plane \
    --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)

  info "Workers (${#WORKER_NODES[@]}):       ${WORKER_NODES[*]}"
  info "Control plane (${#CP_NODES[@]}):  ${CP_NODES[*]}"

  COUNT=0
  TOTAL=$(( ${#WORKER_NODES[@]} + ${#CP_NODES[@]} ))

  for NODE in "${WORKER_NODES[@]}" "${CP_NODES[@]}"; do
    COUNT=$((COUNT + 1))
    migrate_node "${NODE}" "${COUNT}" "${TOTAL}"
  done

  green "All ${TOTAL} nodes migrated to Cilium"

  # ── Phase 3: Finalize ─────────────────────────────────────────────────────
  header "Phase 3/3 — Finalize: switch Cilium to primary CNI"
  info "Values: values.yaml + values.azure-talos.yaml + values.final.yaml"

  helm upgrade "${HELM_RELEASE}" "${HELM_CHART}" \
    --namespace "${HELM_NAMESPACE}" \
    --version "${ISOVALENT_VERSION}" \
    --values "${HELM_VALUES}" \
    --values "${HELM_VALUES_ENV}" \
    --values "${HELM_VALUES_FINAL}" \
    --wait \
    --timeout 12m

  green "Cilium upgraded to primary CNI mode (NetworkPolicy enabled, eBPF host routing)"

  kubectl delete -n "${HELM_NAMESPACE}" ciliumnodeconfig cilium-default --ignore-not-found
  green "CiliumNodeConfig migration resource removed"

  remove_flannel
  restart_coredns

  header "Validate"
  bash "${SCRIPT_DIR}/validate-cilium.sh"

  echo ""
  green "Dual-overlay migration complete."
  echo ""
  echo "  Pod CIDR (Cilium): 10.245.0.0/16"
  echo "  Run: make hubble   → http://localhost:12000"
  echo "  Run: make validate → re-run validation at any time"
}

# ─── run_clean_install ────────────────────────────────────────────────────────
run_clean_install() {
  # Flannel is absent. Install Cilium directly.
  # Root fix for previous failure: k8sServiceHost must be an internal CP node
  # IP (10.0.1.4), not the Azure external LB (20.120.8.75). Azure LBs do not
  # allow inbound traffic from within the same VNet (hairpin restriction).
  # values.azure-talos.yaml already contains the corrected value.

  header "Clean install — Flannel already removed"
  info "Chart:          ${HELM_CHART}@${ISOVALENT_VERSION}"
  info "Values:         values.yaml + values.azure-talos.yaml"
  info "k8sServiceHost: 10.0.1.4 (internal CP node — bypasses Azure LB hairpin)"
  echo ""

  helm upgrade --install "${HELM_RELEASE}" "${HELM_CHART}" \
    --namespace "${HELM_NAMESPACE}" \
    --create-namespace \
    --version "${ISOVALENT_VERSION}" \
    --values "${HELM_VALUES}" \
    --values "${HELM_VALUES_ENV}" \
    --wait \
    --timeout 15m

  green "Cilium installed"

  restart_coredns

  header "Validate"
  bash "${SCRIPT_DIR}/validate-cilium.sh"

  echo ""
  green "Installation complete."
  echo ""
  echo "  Pod CIDR (Cilium): 10.244.0.0/16"
  echo "  Run: make hubble   → http://localhost:12000"
  echo "  Run: make validate → re-run validation at any time"
}

# ─── Prerequisites ────────────────────────────────────────────────────────────
header "Prerequisites"

if ! kubectl get nodes &>/dev/null; then
  die "Cannot reach cluster. Check KUBECONFIG and network."
fi
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
CP_READY=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null \
  | grep " Ready " | wc -l | tr -d ' ' || echo 0)
green "Cluster reachable — ${NODE_COUNT} nodes, ${CP_READY} control plane Ready"

if kubectl -n "${HELM_NAMESPACE}" get ds cilium &>/dev/null; then
  die "Cilium DaemonSet already exists. Use 'make upgrade' to upgrade an existing install."
fi
green "No existing Cilium installation"

if kubectl -n "${HELM_NAMESPACE}" get ds kube-flannel &>/dev/null; then
  green "Flannel DaemonSet present — using dual-overlay migration path"
  MIGRATION_MODE="dual-overlay"
else
  yellow "Flannel DaemonSet absent — using clean install path"
  MIGRATION_MODE="clean-install"
fi

# ─── Helm repo ────────────────────────────────────────────────────────────────
header "Helm repo"
helm repo add isovalent "${ISOVALENT_HELM_REPO}" --force-update 2>/dev/null
helm repo update isovalent 2>/dev/null
green "Isovalent Helm repo ready"

# ─── Chart version ────────────────────────────────────────────────────────────
header "Chart version"
if [[ -n "${ISOVALENT_VERSION:-}" ]]; then
  green "Using pinned ISOVALENT_VERSION=${ISOVALENT_VERSION}"
else
  ISOVALENT_VERSION=$(
    helm search repo "${HELM_CHART}" --versions 2>/dev/null \
      | grep -v -E "dev|beta|alpha|9999|NAME" \
      | awk 'NR==1{print $2}'
  )
  [[ -z "${ISOVALENT_VERSION}" ]] && die "Could not discover chart version. Run: make discover-version"
  green "Auto-discovered: ${HELM_CHART}@${ISOVALENT_VERSION}"
fi

# ─── Dispatch ─────────────────────────────────────────────────────────────────
if [[ "${MIGRATION_MODE}" == "dual-overlay" ]]; then
  run_dual_overlay_migration
else
  run_clean_install
fi
