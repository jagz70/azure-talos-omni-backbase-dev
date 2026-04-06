# Isovalent Enterprise for Cilium — Deployment Guide

**Initiative:** azure talos omni backbase dev
**Target:** Isovalent Enterprise Platform v25.11
**Method:** Helm
**Author:** Julio Garcia

---

## Overview

This directory contains the Helm values and deployment assets for Isovalent Enterprise for Cilium on the `talos-omni-backbase-dev` cluster.

The primary reference for this installation is:
- [Isovalent Enterprise v25.11 generic install](https://docs.isovalent.com/v25.11/ink/install/generic.html) *(customer access required)*
- [Cilium Helm reference](https://docs.cilium.io/en/stable/helm-reference.html) *(secondary — for value semantics)*

---

## Files

| File | Purpose | Committed |
|---|---|---|
| `values.yaml` | Baseline Helm values — non-secret defaults | Yes |
| `values.azure-talos.yaml` | Azure + Talos-specific overrides | Yes |
| `secrets.example.yaml` | Template for operator-supplied secret inputs | Yes (no real values) |

**Never commit a `secrets.yaml` with real values.** Use `.env` for credentials.

---

## Operator-Supplied Inputs

Before installing, you must supply these inputs. None of them are committed to Git.

| Input | Source | How to supply |
|---|---|---|
| Isovalent Helm repo URL | Isovalent customer portal | `ISOVALENT_HELM_REPO` in `.env` |
| Helm repo credentials (if required) | Isovalent customer portal | `ISOVALENT_HELM_USERNAME` + `ISOVALENT_HELM_TOKEN` in `.env` |
| Exact chart version | Isovalent customer portal / release notes | `ISOVALENT_VERSION` in `.env` |
| License key (if required) | Isovalent customer portal | `ISOVALENT_LICENSE_KEY` in `.env` |
| kubeconfig | Omni UI download | `KUBECONFIG` in `.env` |

Verify these by running:
```bash
make env-check
```

---

## Installation

```bash
# From repo root:
make preflight
make install
make validate
```

The `install` target calls `scripts/install-cilium.sh`, which:
1. Sources `.env`
2. Adds the Isovalent Helm repo (with credentials if set)
3. Creates the `isovalent-pull-secret` imagePullSecret in `kube-system` (if credentials are provided)
4. Runs `helm upgrade --install` with both values files

---

## Baseline Configuration Summary

| Feature | Value |
|---|---|
| kube-proxy replacement | `true` (full eBPF replacement) |
| IPAM mode | `cluster-pool` |
| Pod CIDR | `10.244.0.0/16` |
| Hubble | Enabled |
| Hubble relay | Enabled |
| Hubble UI | Enabled |
| Tunnel protocol | VXLAN (default for Azure non-native-routing) |
| Talos compatibility | Configured (capabilities, cgroup mounts) |

---

## Helm Release Reference

```bash
# Release name
cilium

# Namespace
kube-system

# Check current release status
helm status cilium -n kube-system

# Show current release values
helm get values cilium -n kube-system

# Show release history
helm history cilium -n kube-system
```

---

## Upgrade

See [docs/runbooks/cilium-upgrade.md](../../docs/runbooks/cilium-upgrade.md) for the full upgrade procedure.

Quick path:
```bash
# Update ISOVALENT_VERSION in .env, then:
make upgrade
make validate
```

---

## Rollback

```bash
make rollback-help
```

See [docs/runbooks/cilium-rollback.md](../../docs/runbooks/cilium-rollback.md) for the full rollback procedure.
