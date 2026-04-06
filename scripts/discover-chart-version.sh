#!/usr/bin/env bash
# scripts/discover-chart-version.sh
# Inspects the Isovalent Helm repo and lists available chart versions.
# Use this to determine which ISOVALENT_VERSION / HELM_CHART to use.
#
# The Isovalent Helm repo is publicly accessible — no credentials required.
#
# Usage:
#   bash scripts/discover-chart-version.sh
#   make discover-version
#
# Author: Julio Garcia

set -euo pipefail

ISOVALENT_HELM_REPO="${ISOVALENT_HELM_REPO:-https://helm.isovalent.com}"

echo ""
echo "==> Isovalent Helm repository: ${ISOVALENT_HELM_REPO}"
echo "    (publicly accessible — no credentials required)"
echo ""

# ─── Add / refresh the Helm repo ─────────────────────────────────────────────
echo "==> Refreshing Helm repo index..."
helm repo add isovalent "${ISOVALENT_HELM_REPO}" --force-update --quiet 2>/dev/null \
  || helm repo add isovalent "${ISOVALENT_HELM_REPO}" --force-update 2>&1
helm repo update isovalent --quiet 2>/dev/null || helm repo update isovalent
echo ""

# ─── cilium-enterprise chart ──────────────────────────────────────────────────
echo "────────────────────────────────────────────────────────────────────"
echo "  Chart: isovalent/cilium-enterprise  (enterprise-specific chart)"
echo "────────────────────────────────────────────────────────────────────"
helm search repo isovalent/cilium-enterprise --versions 2>/dev/null \
  | grep -v -E "dev|beta|alpha|9999" \
  | head -15 \
  || echo "  (no results — chart may have been superseded, see isovalent/cilium below)"
echo ""

# ─── cilium chart (unified enterprise + community from Isovalent repo) ────────
echo "────────────────────────────────────────────────────────────────────"
echo "  Chart: isovalent/cilium  (unified chart, includes enterprise releases)"
echo "────────────────────────────────────────────────────────────────────"
helm search repo isovalent/cilium --versions 2>/dev/null \
  | grep -v -E "dev|beta|alpha|9999|cilium-enterprise|cilium-dnsproxy" \
  | head -15
echo ""

# ─── Recommendation ───────────────────────────────────────────────────────────
echo "────────────────────────────────────────────────────────────────────"
echo "  Targeting: Isovalent Enterprise Platform v25.11"
echo "  (November 2025 platform release)"
echo ""
echo "  Recommended: check which chart version aligns with your Isovalent"
echo "  customer entitlement and the v25.11 release notes."
echo ""
echo "  For cilium-enterprise, the latest stable is:"
helm search repo isovalent/cilium-enterprise 2>/dev/null \
  | grep -v -E "dev|beta|alpha|9999|NAME" \
  | head -1 \
  | awk '{printf "    HELM_CHART=isovalent/cilium-enterprise\n    ISOVALENT_VERSION=%s\n", $2}' \
  || echo "    (run discover again after helm repo add)"
echo ""
echo "  For isovalent/cilium (newer unified chart), the latest stable is:"
helm search repo isovalent/cilium 2>/dev/null \
  | grep -v -E "dev|beta|alpha|9999|enterprise|dnsproxy|NAME" \
  | head -1 \
  | awk '{printf "    HELM_CHART=isovalent/cilium\n    ISOVALENT_VERSION=%s\n", $2}' \
  || echo "    (run discover again after helm repo add)"
echo ""
echo "  Set HELM_CHART and ISOVALENT_VERSION in .env, then run: make install"
echo "────────────────────────────────────────────────────────────────────"
echo ""
