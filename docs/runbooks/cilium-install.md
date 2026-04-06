# Runbook: Isovalent Enterprise for Cilium — Installation

**Initiative:** azure talos omni backbase dev
**Author:** Julio Garcia

---

## Overview

This runbook covers the step-by-step installation of Isovalent Enterprise for Cilium on the `talos-omni-backbase-dev` cluster via Helm.

**Key facts confirmed from runtime discovery:**
- Helm repo `https://helm.isovalent.com` is **publicly accessible** — no credentials required
- Chart: `isovalent/cilium-enterprise` (enterprise-specific), or `isovalent/cilium` (unified, newer releases)
- Version is **auto-discovered** at install time if not pinned in `.env`
- The install script handles version discovery automatically

---

## Prerequisites

Complete `environments/dev/preflight-checklist.md` first. Quick check:

```bash
# All control plane nodes must be Ready before proceeding
kubectl get nodes -l node-role.kubernetes.io/control-plane
# All must show Ready — stop if any are not

# kube-proxy must not be running (expected on Talos/Omni)
kubectl -n kube-system get ds kube-proxy 2>&1
# Expected: Error from server (NotFound)

# No existing CNI
kubectl -n kube-system get ds cilium 2>&1
# Expected: Error from server (NotFound)
```

---

## Required Operator Input

**Only one item is required before install:**

| Input | How to get it |
|---|---|
| `KUBECONFIG` path | Download from Omni: https://bellyupdown.na-west-1.omni.siderolabs.io/clusters → talos-omni-backbase-dev → Download kubeconfig |

Everything else has working defaults or is auto-discovered.

---

## Installation Steps

### Step 1 — Create .env (one-time setup)

```bash
cp .env.example .env
```

Edit `.env` — set only `KUBECONFIG`:
```bash
KUBECONFIG=/path/to/talos-omni-backbase-dev-kubeconfig.yaml
```

All other values are already set as defaults in the scripts and Makefile:
- `CLUSTER_API_ENDPOINT=20.120.8.75` (autodiscovered, hardcoded as default)
- `HELM_CHART=isovalent/cilium-enterprise` (default)
- `ISOVALENT_VERSION` — auto-discovered at install time if not set

### Step 2 — Run preflight

```bash
make preflight
```

Fix any `FAIL` items before continuing.

### Step 3 — (Optional) Inspect chart versions

```bash
make discover-version
```

Shows available stable versions for both `cilium-enterprise` and `cilium` charts. Use this to:
- Confirm what versions are available
- Pin a specific version in `.env` if required

To pin a version (recommended for repeatability):
```bash
# In .env — add one of these based on discover-version output:
HELM_CHART=isovalent/cilium-enterprise
ISOVALENT_VERSION=1.17.7
```

If you don't pin, the install auto-discovers and uses the latest stable.

### Step 4 — (Optional) Dry run

```bash
make dry-run
```

Renders the full Helm template output without touching the cluster. Useful for reviewing what will be applied.

### Step 5 — Install

```bash
make install
```

The install script will:
1. Add the Isovalent Helm repo (public, no auth)
2. Discover the latest stable version if `ISOVALENT_VERSION` is not set
3. Log the resolved chart and version before installing
4. Run `helm upgrade --install` with both values files
5. Wait for all pods to become ready (`--atomic --timeout 10m`)

Expected output:
```
==> Loaded .env
==> Checking required inputs...
    KUBECONFIG:           /path/to/kubeconfig
    CLUSTER_API_ENDPOINT: 20.120.8.75
    HELM_CHART:           isovalent/cilium-enterprise
...
==> Adding Isovalent Helm repo (public, no credentials required)...
==> ISOVALENT_VERSION not set — discovering latest stable...
    Auto-discovered: 1.17.7
    To pin: add ISOVALENT_VERSION=1.17.7 to .env
==> Running helm upgrade --install...
    Chart:   isovalent/cilium-enterprise@1.17.7
...
==> Isovalent Enterprise for Cilium installed successfully.
    Next: make validate
```

Expected duration: 3–8 minutes.

### Step 6 — Validate

```bash
make validate
```

See [cilium-validate.md](cilium-validate.md) for expected output and failure modes.

### Step 7 — Access Hubble

```bash
make hubble
# → Open http://localhost:12000
```

---

## Expected Post-Install State

```bash
kubectl -n kube-system get pods | grep -E "cilium|hubble"
```

```
cilium-<hash>              1/1   Running   0   5m   ← one per node
cilium-operator-<hash>     1/1   Running   0   5m
hubble-relay-<hash>        1/1   Running   0   5m
hubble-ui-<hash>           2/2   Running   0   5m
```

```bash
kubectl -n kube-system exec -it ds/cilium -- cilium status | grep -E "KubeProxy|IPAM|Hubble"
# KubeProxyReplacement: True
# IPAM: ... 10.244.0.0/16 ...
# Hubble: Ok
```

---

## Chart Selection Reference

| Chart | Versions | Notes |
|---|---|---|
| `isovalent/cilium-enterprise` | up to ~1.17.7 (Aug 2025) | Enterprise-specific chart, older releases |
| `isovalent/cilium` | 1.17.8+, 1.18.x (newer) | Unified chart, includes enterprise features |

Both charts are on the same public repo (`https://helm.isovalent.com`). Use `make discover-version` to see what is currently available and choose based on your Isovalent entitlement.

For Isovalent Enterprise Platform v25.11 (November 2025 platform target), use `make discover-version` to identify the appropriate version and pin it in `.env`.

---

## Rollback

If the install fails mid-way:
```bash
helm uninstall cilium -n kube-system --wait
```

Re-run preflight and retry.

If the install completed but the cluster is unhealthy, see [cilium-rollback.md](cilium-rollback.md).
