# Runbook: CNI Migration — Flannel to Isovalent Enterprise for Cilium

**Initiative:** azure talos omni backbase dev
**Author:** Julio Garcia
**Reference:** https://docs.cilium.io/en/latest/installation/k8s-install-migration/

---

## Background

The `talos-omni-backbase-dev` cluster was provisioned by Omni with **Flannel** as the default
CNI and **kube-proxy** running on all nodes. Cilium must replace both.

This runbook documents the **dual-overlay migration model**, which is the supported approach
for live clusters. Flannel and Cilium coexist during migration — pods are never left without
a working CNI, and nodes are migrated one at a time without a full cluster outage.

**Confirmed live cluster state (verified 2026-04-06):**
- Kubernetes: v1.35.2 / Talos: v1.12.5
- CNI: Flannel (VXLAN, pod CIDR 10.244.0.0/16)
- kube-proxy: DaemonSet (8 nodes)
- Nodes: 3 control plane (10.0.1.4-6) + 5 workers (10.0.2.4-8)
- Omni instance: `bellyupdown.na-west-1.omni.siderolabs.io`

---

## Why direct hard-cutover fails

Removing Flannel, then installing Cilium causes two problems:

1. **Azure LB hairpin restriction** — The Azure external Load Balancer (20.120.8.75)
   does not allow inbound traffic from within the same VNet. Cilium's `config` init
   container connects to `k8sServiceHost` before eBPF is active. If `k8sServiceHost`
   is set to the external LB IP, the init container times out.
   **Fix:** `k8sServiceHost: "10.0.1.4"` (internal CP node IP, already applied in
   `values.azure-talos.yaml`).

2. **No CNI gap** — Between Flannel removal and Cilium readiness, the cluster has no
   CNI. New pods cannot start, and the Cilium pods themselves encounter network issues
   during bootstrap.
   **Fix:** Dual-overlay migration — Flannel stays running while Cilium bootstraps.

---

## Migration model: dual-overlay

```
DURING MIGRATION
─────────────────────────────────────────────────────
Flannel overlay:  VXLAN port 8472, CIDR 10.244.0.0/16
Cilium overlay:   VXLAN port 8473, CIDR 10.245.0.0/16
Linux routing table separates traffic between overlays.

Per-node: when a node is labeled, Cilium becomes the active CNI on that node.
New pods on migrated nodes get IPs from 10.245.0.0/16.
Existing pods on that node (drained before migration) reschedule with Cilium IPs.
```

---

## Automated migration (recommended)

The entire migration is handled by one command:

```bash
make migrate-to-cilium
```

The script auto-detects cluster state:
- **Flannel present** → dual-overlay migration (3 phases)
- **Flannel absent** → clean install with corrected `k8sServiceHost`

---

## Phases

### Phase 1 — Install Cilium in secondary/migration mode

Cilium is installed with `values.migration.yaml` overlay applied after
`values.azure-talos.yaml`. Cilium establishes its overlay but does NOT
take over CNI on any node yet.

Key values in `values.migration.yaml`:
```yaml
cni:
  customConf: true   # don't write CNI conf globally
  uninstall: false   # don't remove Flannel's conf
  exclusive: false
operator:
  unmanagedPodWatcher:
    restart: false
ipam:
  operator:
    clusterPoolIPv4PodCIDRList: ["10.245.0.0/16"]
tunnelPort: 8473
policyEnforcementMode: "never"
bpf:
  hostLegacyRouting: true
```

A `CiliumNodeConfig` is applied that nodes opt into via label:
```yaml
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
```

### Phase 2 — Per-node migration

**Workers first, then control plane.** For each node:

```bash
# Cordon
kubectl cordon $NODE

# Drain (remove non-DaemonSet pods)
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --force --timeout=5m

# Label — activates CiliumNodeConfig, Cilium writes CNI conf on this node
kubectl label node $NODE --overwrite "io.cilium.migration/cilium-default=true"

# Restart Cilium pod on this node
kubectl -n kube-system delete pod --field-selector spec.nodeName=$NODE -l k8s-app=cilium

# Wait for Cilium pod Ready on this node
kubectl -n kube-system rollout status ds/cilium -w

# Uncordon — new pods get Cilium IPs (10.245.0.0/16)
kubectl uncordon $NODE
```

The drain ensures no Flannel-networked pods remain on the node when Cilium
takes over. After labeling + Cilium restart, `cni-exclusive: true` in the
CiliumNodeConfig removes Flannel's CNI conf from that node.

### Phase 3 — Finalize

```bash
# Upgrade Cilium to primary CNI mode
helm upgrade cilium isovalent/cilium \
  -f values.yaml -f values.azure-talos.yaml -f values.final.yaml

# Remove CiliumNodeConfig
kubectl delete -n kube-system ciliumnodeconfig cilium-default

# Remove Flannel
kubectl -n kube-system delete ds kube-flannel

# Restart CoreDNS
kubectl rollout restart deployment/coredns -n kube-system
```

Key values in `values.final.yaml`:
```yaml
cni:
  customConf: false   # Cilium is primary — write CNI conf on all nodes
  exclusive: true
operator:
  unmanagedPodWatcher:
    restart: true     # Recycle any remaining Flannel-managed pods
policyEnforcementMode: "default"
bpf:
  hostLegacyRouting: false  # Full eBPF host routing
```

---

## Note on Omni CNI management

**No Omni UI action is required before migration.**

Verified via `omnictl` API queries:
- Cluster spec has no CNI field
- All config patches are per-machine hostname patches only
- `ClusterBootstrapStatus.bootstrapped: true` — bootstrap is one-time, not re-run
- Flannel and kube-proxy DaemonSets have no `ownerReferences`, no Omni labels

Omni deployed Flannel once at bootstrap. Deleting it is permanent.

---

## Note on kube-proxy

kube-proxy must be removed before or during migration since Cilium provides
kube-proxy replacement (eBPF service routing). `kubeProxyReplacement: true`
is set in `values.yaml` and is active from the moment Cilium pods start —
including in migration/secondary mode. This ensures ClusterIP routing works
throughout the migration even if kube-proxy is removed first.

```bash
kubectl -n kube-system delete ds kube-proxy
kubectl -n kube-system delete cm kube-proxy 2>/dev/null || true
```

---

## Post-migration checklist

- [ ] `make validate` passes all checks
- [ ] `kubectl get nodes` — all nodes Ready
- [ ] `kubectl -n kube-system get pods` — all Cilium + Hubble pods Running
- [ ] `cilium status` shows: `KubeProxyReplacement: True`
- [ ] `cilium status` shows: `IPAM: cluster-pool (10.245.0.0/16)` (dual-overlay path)
- [ ] Hubble UI shows flows: `make hubble` → http://localhost:12000
- [ ] DNS resolution working (dns-test pod)

---

## Rollback

If migration fails at any phase:

```bash
# Remove Cilium
helm uninstall cilium -n kube-system --wait 2>/dev/null || true

# Remove migration CiliumNodeConfig
kubectl delete -n kube-system ciliumnodeconfig cilium-default 2>/dev/null || true

# Remove migration labels from all nodes
kubectl label nodes --all "io.cilium.migration/cilium-default-" 2>/dev/null || true

# Restore Flannel (if it was removed)
# Use the Talos-specific image that Omni originally deployed:
# ghcr.io/siderolabs/flannel:v0.27.4
# Re-apply the original Omni-provided Flannel manifest or the standard manifest:
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# Restore kube-proxy if needed
kubectl apply -f https://raw.githubusercontent.com/kubernetes/kubernetes/v1.35.2/cluster/addons/kube-proxy/kube-proxy.yaml
```

> Omni does not manage CNI after bootstrap. Flannel must be re-applied manually.

---

## Escalation

1. Collect support bundle: `make support-bundle`
2. Isovalent enterprise support: support.isovalent.com
3. Sidero Labs (Talos/Omni): support.siderolabs.com
