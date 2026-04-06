# Network Design

**Initiative:** azure talos omni backbase dev
**Author:** Julio Garcia

---

## Address Space

| Network | CIDR | Purpose |
|---|---|---|
| Azure VNET | 10.0.0.0/16 | All Azure-allocated addresses |
| Control plane subnet | 10.0.1.0/24 | Talos control plane VMs |
| Worker subnet | 10.0.2.0/24 | Talos worker VMs |
| Pod network (cluster-pool) | 10.244.0.0/16 | Kubernetes pod addresses |
| Service network | 10.96.0.0/12 | Kubernetes ClusterIP services |

**No overlaps exist between Azure VNET space and pod/service CIDRs.**

---

## Azure Network Components

### VNET: talos-vnet

- Address space: `10.0.0.0/16`
- Resource group: `base-dojo-rg`
- Region: `eastus`

### Subnets

| Subnet | CIDR | Associated NSG | Purpose |
|---|---|---|---|
| controlplane-subnet | 10.0.1.0/24 | talos-cp-nsg | Control plane nodes |
| worker-subnet | 10.0.2.0/24 | (none in baseline) | Worker nodes |

### Load Balancer: talos-lb

- SKU: Standard
- Frontend IP: `talos-lb-ip` (public, static) → `20.120.8.75`
- Backend pool: `talos-cp-pool` (control plane VMs)
- Load balancing rule: TCP 6443 → 6443 (Kubernetes API)
- Health probe: TCP 6443

### NSG: talos-cp-nsg (control plane subnet)

| Rule | Priority | Direction | Protocol | Port | Source | Action |
|---|---|---|---|---|---|---|
| allow-k8s-api | 100 | Inbound | TCP | 6443 | Any | Allow |
| allow-talos-api | 110 | Inbound | TCP | 50000 | Any | Allow |
| allow-etcd | 120 | Inbound | TCP | 2379-2380 | 10.0.1.0/24 | Allow |

---

## Cilium / Isovalent Network Model

### IPAM: cluster-pool

Cilium manages pod IP allocation using the `cluster-pool` IPAM mode. Each node receives a per-node pod CIDR carved from the cluster-wide pool `10.244.0.0/16`.

- Each node gets a /24 by default (configurable)
- No Azure IPAM integration required — pod IPs are internal to Cilium's overlay
- This avoids Azure CNI delegation complexity and is appropriate for Talos

### kube-proxy Replacement

Cilium replaces kube-proxy entirely using eBPF. This is required because:
1. Talos does not run kube-proxy by default when CNI is set to `none` via Omni
2. eBPF-based service routing provides lower latency and higher observability than iptables

Cilium is configured with:
```yaml
kubeProxyReplacement: true
k8sServiceHost: 20.120.8.75
k8sServicePort: 6443
```

### Node-to-Node Connectivity

Cilium on Azure uses VXLAN encapsulation (tunnel mode) for pod-to-pod traffic across nodes. Azure routing handles node-to-node traffic at the VNET level. Pod traffic is encapsulated in VXLAN and tunneled over the Azure VNET underlay.

- Tunnel protocol: VXLAN (default for non-native-routing Azure)
- Native routing is not enabled in baseline (Azure route table modifications not required)

### Service Handling

- ClusterIP services: handled via eBPF in kube-proxy replacement mode
- NodePort services: handled via eBPF
- LoadBalancer services: Azure Load Balancer controller (standard Kubernetes cloud-provider-azure)

---

## Hubble Observability

Hubble is Cilium's network observability layer. It captures all L3/L4/L7 flow data from the eBPF datapath.

| Component | Description |
|---|---|
| Hubble agent | Runs on each node as part of the Cilium DaemonSet |
| Hubble relay | Aggregates flows from all nodes, exposes gRPC API |
| Hubble UI | Web-based flow visualization |
| Hubble CLI | Command-line flow query and filtering |

Hubble relay is accessible within the cluster at `hubble-relay.kube-system.svc.cluster.local:80`.

For local access, use `make hubble` to port-forward Hubble UI to `http://localhost:12000`.

---

## Future Network Expansion (Planned, Not Implemented)

| Track | Description |
|---|---|
| BGP | Advertise pod CIDRs to Azure routers for native routing (eliminates VXLAN) |
| Gateway API | Replace Ingress with Gateway API for L7 routing |
| Network Policy | Cilium network policies (L3/L4/L7) for workload isolation |
| Encryption | WireGuard node-to-node encryption via Cilium |

These tracks are documented in Phase 4 of the initiative plan and will be designed when the baseline is stable.
