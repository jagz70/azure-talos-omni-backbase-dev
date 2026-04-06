# azure-talos-omni-backbase-dev

Platform engineering initiative: Backbase self-hosted on Azure using Talos Linux managed by Omni, with Isovalent Enterprise for Cilium as the dataplane.

---

## Architecture Overview

| Layer | Technology | Managed By |
|---|---|---|
| VM / Network substrate | Microsoft Azure (eastus) | Azure |
| OS / Kubernetes | Talos Linux | Omni |
| Cluster lifecycle | Omni | Omni |
| Container networking (CNI) | Isovalent Enterprise for Cilium v25.11 | This repo + Helm |
| Application workloads | Backbase (future) | GitOps |

**This repo does not manage cluster lifecycle.** Omni owns machine registration, control-plane orchestration, node scaling, and OS upgrades. This repo holds the deployment assets, runbooks, and automation for the layers Omni does not own.

---

## Environment

| Parameter | Value |
|---|---|
| Cloud | Microsoft Azure |
| Region | eastus |
| Resource Group | base-dojo-rg |
| Subscription | EB Azure Training |
| VNET | talos-vnet (10.0.0.0/16) |
| Control Plane Subnet | controlplane-subnet (10.0.1.0/24) |
| Worker Subnet | worker-subnet (10.0.2.0/24) |
| Load Balancer IP | 20.120.8.75 |
| Omni Instance | bellyupdown.na-west-1.omni.siderolabs.io |
| Cluster Name | talos-omni-backbase-dev |
| Cluster Shape | 3 control plane + 5 workers |

---

## Quick Start

### Current Cluster State

> **CNI migration required.** This cluster was provisioned by Omni with Flannel as the default CNI and kube-proxy running. Before installing Cilium, follow [docs/runbooks/cni-migration-flannel-to-cilium.md](docs/runbooks/cni-migration-flannel-to-cilium.md) to remove Flannel and kube-proxy.
>
> Cluster: `talos-omni-backbase-dev` — k8s v1.35.2, Talos v1.12.5, 3 CP + 5 workers

### Prerequisites

- `kubectl` configured (kubeconfig from Omni — see below)
- `helm` >= 3.12
- `az` CLI authenticated (`az login`)

**The Isovalent Helm repo (`https://helm.isovalent.com`) is publicly accessible. No credentials required.**

### Get kubeconfig from Omni

1. Go to [Omni cluster page](https://bellyupdown.na-west-1.omni.siderolabs.io/clusters)
2. Select cluster `talos-omni-backbase-dev`
3. Download the kubeconfig
4. Set `KUBECONFIG=/path/to/downloaded-kubeconfig.yaml` in your `.env`

**Do not store the kubeconfig in this repo.**

### Set up your local environment

```bash
cp .env.example .env
# Only required: set KUBECONFIG path
# All other values have working defaults
```

### Run preflight checks

```bash
make preflight
```

### (Optional) Inspect available chart versions

```bash
make discover-version
# Shows available isovalent/cilium-enterprise and isovalent/cilium versions
# Optionally pin ISOVALENT_VERSION in .env — or let install auto-discover
```

### (Optional) Dry run — render templates without applying

```bash
make dry-run
```

### Install Isovalent Enterprise for Cilium

```bash
make install
# If ISOVALENT_VERSION is not set in .env, the latest stable is auto-discovered
```

### Validate the installation

```bash
make validate
```

### Access Hubble UI

```bash
make hubble
```

---

## Make Targets

| Target | Description |
|---|---|
| `make preflight` | Run pre-installation checks |
| `make discover-version` | List available chart versions from Isovalent Helm repo |
| `make dry-run` | Render Helm templates without applying to cluster |
| `make install` | Install Isovalent Enterprise for Cilium via Helm (auto-discovers version if not pinned) |
| `make validate` | Validate Cilium + Hubble health |
| `make upgrade` | Upgrade Isovalent Enterprise in place |
| `make rollback-help` | Print rollback guidance and commands |
| `make status` | Show Cilium pod and node status (quick) |
| `make hubble` | Port-forward Hubble UI to localhost:12000 |
| `make hubble-relay` | Port-forward Hubble relay gRPC to localhost:4245 (for hubble CLI) |
| `make support-bundle` | Collect diagnostic bundle (logs, status, events) |
| `make helm-history` | Show Helm release history |
| `make helm-values` | Show current deployed Helm values |
| `make helm-diff` | Diff a pending upgrade (requires helm-diff plugin) |
| `make logs-cilium` | Tail Cilium agent logs across all nodes |
| `make logs-operator` | Tail Cilium operator logs |
| `make logs-hubble-relay` | Tail Hubble relay logs |
| `make env-check` | Verify .env is populated |

---

## Runbooks

| Runbook | Purpose |
|---|---|
| [cni-migration-flannel-to-cilium.md](docs/runbooks/cni-migration-flannel-to-cilium.md) | **Start here** — migrate existing Flannel CNI to Cilium |
| [cilium-install.md](docs/runbooks/cilium-install.md) | Step-by-step Cilium installation |
| [cilium-validate.md](docs/runbooks/cilium-validate.md) | Post-install health validation |
| [cilium-upgrade.md](docs/runbooks/cilium-upgrade.md) | Safe upgrade procedure |
| [cilium-rollback.md](docs/runbooks/cilium-rollback.md) | Helm rollback procedure |
| [hubble-access.md](docs/runbooks/hubble-access.md) | Hubble UI and CLI access guide |
| [node-scaling.md](docs/runbooks/node-scaling.md) | Scale worker nodes via Omni |
| [support-bundle.md](docs/runbooks/support-bundle.md) | Collect diagnostic support bundle |

---

## Repository Structure

```
.
├── README.md                              # This file
├── Makefile                               # Deterministic command surface
├── .gitignore                             # Excludes secrets, kubeconfigs, binaries
├── .env.example                           # Template for operator-supplied inputs
│
├── docs/
│   ├── architecture/
│   │   ├── overview.md                    # Platform architecture
│   │   └── network-design.md             # Network / IPAM design
│   ├── runbooks/
│   │   ├── cilium-install.md             # Install runbook
│   │   ├── cilium-validate.md            # Validation runbook
│   │   ├── cilium-upgrade.md             # Upgrade runbook
│   │   ├── cilium-rollback.md            # Rollback runbook
│   │   ├── hubble-access.md              # Hubble UI + CLI
│   │   ├── node-scaling.md               # Scale nodes via Omni
│   │   └── support-bundle.md             # Support collection
│   ├── lessons-learned/
│   │   └── azure-talos-omni-build.md     # Hard-won build lessons
│   └── operating-model.md                # How to use this repo + Omni
│
├── environments/dev/
│   ├── cluster.env                        # Non-secret cluster parameters
│   └── preflight-checklist.md            # Pre-install checklist
│
├── helm/isovalent-enterprise/
│   ├── README.md                          # Deployment README
│   ├── values.yaml                        # Baseline Helm values
│   ├── values.azure-talos.yaml           # Azure + Talos overlay
│   └── secrets.example.yaml              # Placeholder for secret inputs
│
└── scripts/
    ├── preflight.sh                       # Pre-install checks
    ├── install-cilium.sh                  # Helm install wrapper
    ├── validate-cilium.sh                 # Post-install validation
    └── hubble-port-forward.sh            # Hubble UI local access
```

---

## Omni Relationship

Omni is the lifecycle source of truth for this cluster. Operators use Omni for:
- Adding or removing machines
- Scaling control plane or worker counts
- OS and Kubernetes version upgrades
- Viewing machine registration and health status

This repo is used for:
- CNI installation and configuration (Isovalent Enterprise for Cilium)
- Post-install validation
- Runbooks and operating procedures
- Day-2 operations scripts

See [docs/operating-model.md](docs/operating-model.md) for the full operator workflow.

---

## Secrets Policy

Nothing in this repo contains credentials, tokens, kubeconfigs, or licensed inputs.

| Item | Location | Source |
|---|---|---|
| Kubeconfig | Local only, set in `.env` | Download from Omni |
| Isovalent credentials | Local only, set in `.env` | Isovalent customer portal |
| `.env` | Local only, git-ignored | Operator-created from `.env.example` |

---

## Author

Julio Garcia — Infrastructure Engineering, Eastern Bank
