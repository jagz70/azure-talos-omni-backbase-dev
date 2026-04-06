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

### Prerequisites

- `kubectl` configured (kubeconfig from Omni — see below)
- `helm` >= 3.12
- `az` CLI authenticated (`az login`)
- `.env` file populated (see `.env.example`)

### Get kubeconfig from Omni

1. Go to [Omni cluster page](https://bellyupdown.na-west-1.omni.siderolabs.io/clusters)
2. Select cluster `talos-omni-backbase-dev`
3. Download the kubeconfig
4. Set `KUBECONFIG=/path/to/downloaded-kubeconfig.yaml` in your `.env`

**Do not store the kubeconfig in this repo.**

### Set up your local environment

```bash
cp .env.example .env
# Edit .env and populate all required values
```

### Run preflight checks

```bash
make preflight
```

### Install Isovalent Enterprise for Cilium

```bash
make install
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
| `make install` | Install Isovalent Enterprise via Helm |
| `make validate` | Validate Cilium + Hubble health |
| `make hubble` | Port-forward Hubble UI to localhost:12000 |
| `make upgrade` | Upgrade Isovalent Enterprise in place |
| `make rollback-help` | Print rollback guidance |
| `make status` | Show Cilium pod and node status |
| `make env-check` | Verify .env is populated |

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
