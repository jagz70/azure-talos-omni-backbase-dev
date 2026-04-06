# Platform Architecture Overview

**Initiative:** azure talos omni backbase dev
**Author:** Julio Garcia

---

## Layered Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Application Layer                         │
│              Backbase workloads (future)                     │
├─────────────────────────────────────────────────────────────┤
│                   Container Networking                        │
│         Isovalent Enterprise for Cilium v25.11               │
│    kube-proxy replacement · cluster-pool IPAM · Hubble       │
├─────────────────────────────────────────────────────────────┤
│               Kubernetes / OS Layer                          │
│        Talos Linux  ←  managed by Omni                       │
│   3 control plane nodes  +  5 worker nodes                   │
├─────────────────────────────────────────────────────────────┤
│                  VM / Network Substrate                       │
│              Microsoft Azure — eastus                        │
│    talos-vnet · Standard Load Balancer · NSGs                │
└─────────────────────────────────────────────────────────────┘
```

---

## Component Responsibilities

| Component | Role | Managed By |
|---|---|---|
| Azure VMs | Compute substrate for Talos nodes | Azure (Terraform / manual) |
| Azure VNET / Subnets | L3 network fabric between nodes | Azure |
| Azure Standard LB | External access to Kubernetes API (6443) | Azure |
| Azure NSGs | Inbound port filtering | Azure |
| Talos Linux | Immutable OS, Kubernetes node runtime | Omni |
| Omni | Cluster lifecycle, machine registration, OS upgrades | Omni UI / API |
| Isovalent Enterprise Cilium | CNI, kube-proxy replacement, network policy, Hubble | This repo + Helm |
| Backbase | Application workloads | Future GitOps |

---

## Cluster Topology

| Role | Count | Subnet | Notes |
|---|---|---|---|
| Control plane | 3 | controlplane-subnet (10.0.1.0/24) | etcd, kube-apiserver |
| Workers | 5 | worker-subnet (10.0.2.0/24) | Application workloads |

**Kubernetes API:** `https://20.120.8.75:6443` (via talos-lb public IP)

---

## Omni Lifecycle Model

Omni is the **single source of truth for cluster lifecycle** for this initiative. This is a deliberate architectural choice that differs from standalone Talos deployments.

```
Omni
  ├── Machine registration (via Omni-generated Azure image)
  ├── Control plane bootstrap
  ├── Machine config generation and application
  ├── etcd membership management
  ├── Node OS + Kubernetes version upgrades
  └── Cluster scaling (add / remove machines)

This repo
  ├── CNI installation (Isovalent Enterprise for Cilium)
  ├── Cilium configuration (Helm values)
  ├── Day-2 operations runbooks
  └── Validation and observability scripts
```

**Operators use Omni for machine-level operations and this repo for networking/dataplane operations.**

---

## Isovalent Enterprise for Cilium — Baseline Configuration

| Feature | Setting |
|---|---|
| kube-proxy replacement | Enabled (full replacement) |
| IPAM mode | cluster-pool |
| Pod CIDR | 10.244.0.0/16 |
| Hubble relay | Enabled |
| Hubble UI | Enabled |
| Encryption | Not enabled in baseline (future scope) |
| BGP | Not enabled in baseline (future scope) |
| Gateway API | Not enabled in baseline (future scope) |

---

## Network Address Summary

| Range | Purpose |
|---|---|
| 10.0.0.0/16 | Azure VNET |
| 10.0.1.0/24 | Control plane subnet |
| 10.0.2.0/24 | Worker subnet |
| 10.244.0.0/16 | Pod CIDR (cluster-pool IPAM) |
| 10.96.0.0/12 | Service CIDR |

All ranges are non-overlapping. Pod and service CIDRs are internal to the cluster and not exposed on the Azure VNET.

---

## Access Paths

| Access | Method |
|---|---|
| Kubernetes API | kubectl with kubeconfig from Omni, via 20.120.8.75:6443 |
| Omni cluster management | https://bellyupdown.na-west-1.omni.siderolabs.io/clusters |
| Hubble UI | kubectl port-forward (see runbook) |
| Hubble CLI | Direct from a Cilium pod exec or local hubble binary |
