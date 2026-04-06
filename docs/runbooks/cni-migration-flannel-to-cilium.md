# Runbook: CNI Migration — Flannel to Isovalent Enterprise for Cilium

**Initiative:** azure talos omni backbase dev
**Author:** Julio Garcia

---

## Context

The `talos-omni-backbase-dev` cluster was provisioned by Omni with **Flannel** as the default CNI and **kube-proxy** running on all nodes. Before Isovalent Enterprise for Cilium can be installed, both must be removed.

**Confirmed live cluster state (verified 2026-04-06):**
- Kubernetes: v1.35.2
- Talos: v1.12.5
- Existing CNI: Flannel (VXLAN, pod CIDR 10.244.0.0/16)
- kube-proxy: Running (DaemonSet on all 8 nodes)
- Nodes: 3 control plane (10.0.1.4-6) + 5 workers (10.0.2.4-8)
- All nodes Ready

**This is a live CNI migration, not a fresh install.**

---

## Migration Overview

```
BEFORE                           AFTER
──────────────────────────────   ────────────────────────────────
CNI: Flannel (VXLAN)         →   CNI: Isovalent Enterprise Cilium
kube-proxy: running          →   kube-proxy: removed (eBPF replacement)
Pod networking: Flannel      →   Pod networking: Cilium eBPF
Service routing: iptables    →   Service routing: eBPF
Observability: none          →   Observability: Hubble
```

---

## Impact Assessment

| Risk | Details |
|---|---|
| Pod networking interruption | Existing pods lose network connectivity briefly during CNI switch |
| CoreDNS disruption | CoreDNS pods need restart after Cilium takes over |
| Service disruption | Brief disruption between kube-proxy removal and Cilium startup |
| Duration | ~5–10 minutes total |
| Rollback | Possible — see Rollback section below |

This cluster has no production workloads. POC-grade disruption is acceptable.

---

## Automated Migration (Recommended)

The entire migration is automated by a single command:

```bash
make migrate-to-cilium
```

This script:
1. Validates prerequisites (cluster reachable, no existing Cilium)
2. Removes Flannel DaemonSet, ConfigMap, RBAC, and node annotations
3. Removes kube-proxy DaemonSet and ConfigMap
4. Waits 30 seconds to confirm Omni does not reconcile them back
5. Installs Isovalent Enterprise for Cilium via Helm
6. Restarts CoreDNS
7. Runs full validation

**The manual steps below are for reference only.** Use them if you need to run a partial migration, debug a failure, or understand what the script does.

---

## Pre-Migration Checklist

- [ ] All nodes are Ready: `kubectl get nodes`
- [ ] kubeconfig is downloaded from Omni and working: `kubectl get nodes`
- [ ] You are prepared for ~5 minutes of pod networking disruption
- [ ] `.env` is configured (KUBECONFIG set, HELM_CHART=isovalent/cilium, ISOVALENT_VERSION set or leave blank for auto-discover)
- [ ] Isovalent Helm repo is accessible: `make helm-repo-add`

---

## Note on Omni CNI Management

**No Omni UI action is required before migration.**

This was verified via `omnictl` API queries against the live cluster:

- The Cluster spec (`omnictl get cluster talos-omni-backbase-dev -o yaml`) contains **no CNI field**
- All config patches are per-machine hostname patches only — no CNI configuration
- `ClusterBootstrapStatus.bootstrapped: true` — bootstrap is a one-time event; Omni does not re-run it
- The Flannel and kube-proxy DaemonSets have **no `ownerReferences`** and **no Omni labels**
- `kubectl -n kube-system get all -l "omni.sidero.dev/cluster=talos-omni-backbase-dev"` returns no resources

Omni deployed Flannel once at bootstrap and does not reconcile it. Deleting the DaemonSet is permanent.

The `migrate-to-cilium.sh` script includes a 30-second post-deletion watch to confirm this at runtime.

---

## Step 1 — Remove Flannel

```bash
# Delete the Flannel DaemonSet
kubectl -n kube-system delete ds kube-flannel

# Delete the Flannel ConfigMap
kubectl -n kube-system delete cm kube-flannel-cfg

# Delete Flannel RBAC resources (if present)
kubectl delete clusterrolebinding flannel 2>/dev/null || true
kubectl delete clusterrole flannel 2>/dev/null || true
kubectl delete serviceaccount flannel -n kube-system 2>/dev/null || true

# Verify Flannel pods are gone
kubectl -n kube-system get pods | grep flannel
# Expected: no output
```

> After Flannel is removed, existing running pods retain their IP assignments from Flannel's
> IPAM until they are restarted. New pods will have no CNI until Cilium is installed.
> Work quickly through the next steps.

---

## Step 2 — Remove kube-proxy

Cilium will replace kube-proxy entirely using eBPF. kube-proxy must be removed before
the Cilium install to avoid iptables rule conflicts.

```bash
# Delete kube-proxy DaemonSet
kubectl -n kube-system delete ds kube-proxy

# Delete kube-proxy ConfigMap (if present)
kubectl -n kube-system delete cm kube-proxy 2>/dev/null || true

# Remove kube-proxy iptables rules from all nodes
# Cilium will re-establish service routing via eBPF after installation.
# Existing connections may be disrupted briefly.

# Verify kube-proxy pods are gone
kubectl -n kube-system get pods | grep kube-proxy
# Expected: no output
```

---

## Step 3 — Install Isovalent Enterprise for Cilium

At this point, Flannel and kube-proxy are removed. The cluster has no active CNI or service routing. Install Cilium immediately.

```bash
# From the repo root
make install
```

The install script will:
1. Add the Isovalent Helm repo (public, no auth)
2. Discover the latest stable `isovalent/cilium` chart version (or use pinned `ISOVALENT_VERSION`)
3. Run `helm upgrade --install` with the `values.yaml` and `values.azure-talos.yaml` values files
4. Wait for all Cilium pods to become Ready (--atomic --timeout 10m)

Expected duration: 5–8 minutes.

If install fails, see [cilium-rollback.md](cilium-rollback.md) and the Rollback section below.

---

## Step 4 — Restart CoreDNS

CoreDNS pods still have their old Flannel-assigned IP addresses. Restart them to get
Cilium-managed IPs and restore DNS resolution across the cluster.

```bash
kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout status deployment/coredns -n kube-system --timeout=3m
```

---

## Step 5 — Validate

```bash
make validate
```

All checks must pass before declaring the migration complete.

Also verify DNS resolution and pod-to-pod connectivity:

```bash
# DNS test
kubectl run dns-test --image=busybox:1.36 --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
kubectl logs dns-test
kubectl delete pod dns-test

# Pod-to-pod connectivity test
kubectl run client --image=busybox:1.36 --restart=Never -- sleep 300
kubectl run server --image=busybox:1.36 --restart=Never -- sh -c "nc -l -p 8080"
SERVER_IP=$(kubectl get pod server -o jsonpath='{.status.podIP}')
kubectl exec client -- nc -z -w 3 "${SERVER_IP}" 8080 && echo "PASS"
kubectl delete pod client server
```

---

## Step 6 — Recycle Existing Pods (Optional)

Pods that were running during the migration still have Flannel-assigned networking state cached
in some scenarios. For a clean state, rolling-restart application deployments:

```bash
# Restart any other deployments/daemonsets if they are misbehaving
kubectl get deployments --all-namespaces
# For each affected deployment:
# kubectl rollout restart deployment/<name> -n <namespace>
```

CoreDNS (Step 4) is the most critical. Application pods in this POC cluster are unlikely to
have issues since Cilium preserves the same pod CIDR (10.244.0.0/16).

---

## Step 7 — Access Hubble

```bash
make hubble
# → Open http://localhost:12000
```

Verify flows are visible for kube-system pods. This confirms Cilium's eBPF datapath is active.

---

## Post-Migration Checklist

- [ ] `make validate` passes all checks
- [ ] `kubectl get nodes` — all nodes Ready
- [ ] `kubectl -n kube-system get pods` — all Cilium + Hubble pods Running
- [ ] DNS resolution working (dns-test pod)
- [ ] Pod-to-pod connectivity working
- [ ] Hubble UI showing flows
- [ ] `cilium status` shows: `KubeProxyReplacement: True`
- [ ] `cilium status` shows: `IPAM: ... 10.244.0.0/16`

---

## Rollback

If migration fails and the cluster networking is broken:

### Rollback Cilium (if partially installed)
```bash
helm uninstall cilium -n kube-system --wait 2>/dev/null || true
```

### Restore kube-proxy
```bash
# kube-proxy manifest from upstream (adjust for your k8s version)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/kubernetes/v1.35.2/cluster/addons/kube-proxy/kube-proxy.yaml
# OR re-apply from any backup copy
```

### Restore Flannel
```bash
# Standard Flannel manifest for 10.244.0.0/16
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

**After restoring**: Omni does not manage the CNI after bootstrap. Flannel must be applied manually as shown above — Omni will not re-deploy it automatically.

---

## Escalation

If networking is broken and rollback does not restore it:
1. Collect a support bundle: `make support-bundle`
2. Contact Isovalent enterprise support with the bundle
3. Engage Sidero Labs support for Talos/Omni-specific questions
