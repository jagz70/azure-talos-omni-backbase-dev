# Runbook: Isovalent Enterprise for Cilium — Installation

**Initiative:** azure talos omni backbase dev
**Author:** Julio Garcia

---

## Purpose

Step-by-step installation of Isovalent Enterprise for Cilium v25.11 on the `talos-omni-backbase-dev` cluster via Helm.

This runbook assumes:
- The Omni-managed cluster is healthy (all control plane nodes Ready)
- kubeconfig has been downloaded from Omni
- `.env` has been populated from `.env.example`
- No CNI is currently installed

---

## Prerequisites Checklist

Complete `environments/dev/preflight-checklist.md` before proceeding.

Quick verification:
```bash
# Confirm all CPs are Ready — stop if any are not
kubectl get nodes -l node-role.kubernetes.io/control-plane

# Confirm no kube-proxy (expected on Talos/Omni)
kubectl -n kube-system get ds kube-proxy 2>&1
# Expected: "Error from server (NotFound)"

# Confirm no existing CNI
kubectl -n kube-system get ds cilium 2>&1
# Expected: "Error from server (NotFound)"
```

---

## Required Operator Inputs

Before install, these must be set in `.env`:

| Variable | Description | Source |
|---|---|---|
| `KUBECONFIG` | Path to kubeconfig downloaded from Omni | Omni UI → cluster download |
| `CLUSTER_API_ENDPOINT` | `20.120.8.75` (already known) | autodiscovered |
| `ISOVALENT_HELM_REPO` | Isovalent Helm chart repository URL | Isovalent customer portal |
| `ISOVALENT_VERSION` | Exact chart version for v25.11 | Isovalent customer portal / release notes |
| `ISOVALENT_HELM_USERNAME` | Helm repo username (if required) | Isovalent customer portal |
| `ISOVALENT_HELM_TOKEN` | Helm repo token (if required) | Isovalent customer portal |

> Confirm whether `ISOVALENT_HELM_USERNAME` / `ISOVALENT_HELM_TOKEN` are required by checking
> the Isovalent Enterprise v25.11 install docs at your customer portal:
> https://docs.isovalent.com/v25.11/ink/install/generic.html

---

## Helm Values Reference

| File | Purpose |
|---|---|
| `helm/isovalent-enterprise/values.yaml` | Baseline: kube-proxy replacement, cluster-pool IPAM, Hubble |
| `helm/isovalent-enterprise/values.azure-talos.yaml` | Overlay: Azure VXLAN, Talos capabilities, cgroup mounts |

Both files are committed. Review them before installing:
```bash
cat helm/isovalent-enterprise/values.yaml
cat helm/isovalent-enterprise/values.azure-talos.yaml
```

---

## Installation Steps

### Step 1 — Set up .env

```bash
cp .env.example .env
# Edit .env:
#   KUBECONFIG=/path/to/talos-omni-backbase-dev-kubeconfig.yaml
#   ISOVALENT_VERSION=<confirm from your Isovalent customer portal>
#   ISOVALENT_HELM_USERNAME=<if required>
#   ISOVALENT_HELM_TOKEN=<if required>
```

### Step 2 — Verify .env

```bash
make env-check
```

### Step 3 — Run preflight

```bash
make preflight
```

All checks must pass before proceeding. Fix any failures before continuing.

### Step 4 — Add Isovalent Helm repo

```bash
make helm-repo-add
```

Verify the chart version is available:
```bash
helm search repo isovalent/cilium --versions | head -10
```

### Step 5 — Install

```bash
make install
```

`make install` runs `scripts/install-cilium.sh`, which:
1. Validates all required `.env` variables
2. Adds the Isovalent Helm repo (with auth if credentials are set)
3. Creates `isovalent-pull-secret` in `kube-system` if credentials are provided
4. Runs `helm upgrade --install cilium isovalent/cilium` with both values files
5. Waits for all pods to become ready (`--atomic --timeout 10m`)

Expected duration: 3–8 minutes depending on image pull speed.

### Step 6 — Validate

```bash
make validate
```

See [cilium-validate.md](cilium-validate.md) for expected output and troubleshooting.

---

## Expected Post-Install State

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/part-of=cilium
```

Expected: all pods in `Running` state.

```
NAME                             READY   STATUS    RESTARTS   AGE
cilium-<hash>                    1/1     Running   0          5m   ← one per node
cilium-<hash>                    1/1     Running   0          5m
...
cilium-operator-<hash>           1/1     Running   0          5m
cilium-operator-<hash>           1/1     Running   0          5m
hubble-relay-<hash>              1/1     Running   0          5m
hubble-ui-<hash>                 2/2     Running   0          5m
```

---

## Verification Commands

```bash
# Overall Cilium health (from inside a Cilium pod)
kubectl -n kube-system exec -it ds/cilium -- cilium status

# Confirm kube-proxy replacement is active
kubectl -n kube-system exec -it ds/cilium -- cilium status | grep -i "kube-proxy"

# Confirm IPAM pool
kubectl -n kube-system exec -it ds/cilium -- cilium status | grep -i "ipam"

# Confirm Hubble is running
kubectl -n kube-system get pods | grep hubble

# Access Hubble UI
make hubble
# → Open http://localhost:12000
```

---

## Rollback

If the install fails mid-way:
```bash
helm uninstall cilium -n kube-system --wait
```

Then re-check preflight and retry.

If the install completed but the cluster is unhealthy, see [cilium-rollback.md](cilium-rollback.md).
