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

## Pre-Migration Checklist

- [ ] All nodes are Ready: `kubectl get nodes`
- [ ] kubeconfig is downloaded from Omni and working: `kubectl get nodes`
- [ ] You are prepared for ~5 minutes of pod networking disruption
- [ ] `.env` is configured (KUBECONFIG set, HELM_CHART=isovalent/cilium, ISOVALENT_VERSION set or leave blank for auto-discover)
- [ ] Isovalent Helm repo is accessible: `make helm-repo-add`

---

## Step 1 — Configure Omni to Stop Managing the CNI

**This is the most important step.** If Omni is set to deploy Flannel, it may re-create the Flannel DaemonSet after you delete it.

In Omni UI:
1. Go to: https://bellyupdown.na-west-1.omni.siderolabs.io/clusters
2. Select cluster `talos-omni-backbase-dev`
3. Navigate to cluster configuration / edit
4. Find the **CNI** setting and change it from `flannel` to `none` or `custom`
5. Save and apply the configuration

> If Omni does not have a CNI setting visible in the UI, check the cluster's Kubernetes patches
> or machine config patches section. The setting may appear as:
> ```yaml
> network:
>   cni:
>     name: none
> ```
> Apply this via Omni's cluster configuration patch mechanism.

**Verify Omni will not re-create Flannel before proceeding to Step 2.**

---

## Step 2 — Remove Flannel

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

## Step 3 — Remove kube-proxy

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

## Step 4 — Install Isovalent Enterprise for Cilium

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

## Step 5 — Restart CoreDNS

CoreDNS pods still have their old Flannel-assigned IP addresses. Restart them to get
Cilium-managed IPs and restore DNS resolution across the cluster.

```bash
kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout status deployment/coredns -n kube-system --timeout=3m
```

---

## Step 6 — Validate

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

## Step 7 — Recycle Existing Pods (Optional)

Pods that were running during the migration still have Flannel-assigned networking state cached
in some scenarios. For a clean state, rolling-restart application deployments:

```bash
# Restart any other deployments/daemonsets if they are misbehaving
kubectl get deployments --all-namespaces
# For each affected deployment:
# kubectl rollout restart deployment/<name> -n <namespace>
```

CoreDNS (Step 5) is the most critical. Application pods in this POC cluster are unlikely to
have issues since Cilium preserves the same pod CIDR (10.244.0.0/16).

---

## Step 8 — Access Hubble

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

**After restoring**: Update Omni to set CNI back to `flannel` if Omni was managing it.

> Note: If Omni was configured to use CNI=none (Step 1), Flannel will NOT be automatically
> re-deployed by Omni. You must apply the Flannel manifest manually for rollback.

---

## Escalation

If networking is broken and rollback does not restore it:
1. Collect a support bundle: `make support-bundle`
2. Contact Isovalent enterprise support with the bundle
3. Engage Sidero Labs support for Talos/Omni-specific questions
