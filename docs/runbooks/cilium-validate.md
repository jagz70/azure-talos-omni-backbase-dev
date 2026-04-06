# Runbook: Isovalent Enterprise for Cilium — Validation

**Initiative:** azure talos omni backbase dev
**Author:** Julio Garcia

---

## Purpose

Comprehensive post-installation validation for Isovalent Enterprise for Cilium. Run after every install or upgrade. Use this as the health gate before any production traffic or workload deployment.

---

## Quick Validation

```bash
make validate
```

`make validate` runs `scripts/validate-cilium.sh`, which checks all components listed below and provides a clear pass/fail summary. Fix any `FAIL` items before declaring the installation healthy.

---

## Component-by-Component Checks

### 1. Cilium DaemonSet

Every node must have a running Cilium pod.

```bash
kubectl -n kube-system get ds cilium
```

Expected: `DESIRED` == `READY`. Example for 8-node cluster (3 CP + 5 workers):
```
NAME     DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
cilium   8         8         8       8            8
```

```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
```

Expected: all pods `Running`, no pods in `CrashLoopBackOff` or `Pending`.

---

### 2. Cilium Operator

```bash
kubectl -n kube-system get deploy cilium-operator
```

Expected: `2/2` ready (baseline config sets `replicas: 2`).

```bash
kubectl -n kube-system logs -l name=cilium-operator --tail=20
```

Look for: no `ERROR` or `Fatal` log lines.

---

### 3. Cilium Agent Status

Run from inside a Cilium pod for the authoritative health view:

```bash
kubectl -n kube-system exec -it ds/cilium -- cilium status
```

Expected output (healthy):
```
KVStore:                 Ok
Kubernetes:              Ok   ...
Kubernetes APIs:         ["cilium/v2::CiliumClusterwideNetworkPolicy", ...]
KubeProxyReplacement:    True
Host firewall:           Disabled
CNI Chaining:            none
Cilium:                  Ok    ...
NodeMonitor:             Listening for events on 16 CPUs with 64x4096 of shared memory
Cilium health daemon:    Ok
IPAM:                    IPv4: ... /16 pool
...
Hubble:                  Ok   ...
```

Key fields to check:
- `KubeProxyReplacement: True` — kube-proxy replacement active
- `IPAM:` — shows cluster-pool allocation from `10.244.0.0/16`
- `Hubble: Ok` — observability layer healthy
- `Kubernetes: Ok` — API server reachable

---

### 4. kube-proxy Replacement

```bash
kubectl -n kube-system exec -it ds/cilium -- cilium status | grep -i "kube-proxy"
```

Expected: `KubeProxyReplacement: True` (or `Strict` depending on Cilium version).

Verify service forwarding is eBPF-based:
```bash
kubectl -n kube-system exec -it ds/cilium -- cilium service list
```

All ClusterIP and NodePort services should appear here. If this list is empty and services exist in the cluster, kube-proxy replacement is not functioning correctly.

---

### 5. Hubble Relay

```bash
kubectl -n kube-system get deploy hubble-relay
```

Expected: `1/1` (or `2/2` if configured with multiple replicas).

```bash
kubectl -n kube-system logs -l k8s-app=hubble-relay --tail=20
```

Look for: `"msg":"Starting gRPC server"` — relay is ready to accept flow queries.

---

### 6. Hubble UI

```bash
kubectl -n kube-system get deploy hubble-ui
```

Expected: `1/1` ready.

Quick browser test:
```bash
make hubble
# → Open http://localhost:12000
```

Expected: Hubble UI loads and shows a namespace selector and flow visualization.

---

### 7. Node Networking: Pod-to-Pod Connectivity

Deploy two test pods and verify connectivity:

```bash
# Deploy a temporary test pod
kubectl run test-client --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl run test-server --image=busybox:1.36 --restart=Never -- sh -c "while true; do nc -l -p 8080 -e echo 'hello'; done"

# Wait for pods to be Running
kubectl get pods test-client test-server -w

# Get test-server IP
TEST_SERVER_IP=$(kubectl get pod test-server -o jsonpath='{.status.podIP}')

# Test pod-to-pod connectivity
kubectl exec test-client -- nc -z -w 3 "${TEST_SERVER_IP}" 8080 && echo "PASS: pod-to-pod connectivity OK"

# Clean up
kubectl delete pod test-client test-server
```

---

### 8. DNS Resolution

```bash
kubectl run dns-test --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default.svc.cluster.local
kubectl logs dns-test
kubectl delete pod dns-test
```

Expected: resolution succeeds and returns a ClusterIP address.

---

### 9. Hubble Flow Capture

Verify Hubble is capturing real network flows:

```bash
kubectl -n kube-system exec -it ds/cilium -- hubble observe --last 20
```

Expected: flow entries visible. If the cluster has active workloads, flows should appear immediately.

---

## What a Healthy `cilium status` Looks Like

```
Defaulted container "cilium-agent" out of: cilium-agent, mount-cgroup, ...
KVStore:                 Ok
...
KubeProxyReplacement:    True
...
IPAM:                    IPv4: 8/256 allocated from 10.244.0.0/24, ...
...
Hubble:                  Ok   Current/Max Flows: 4095/4095 (100.00%), Flows/s: 4.78
...
Controller Status:       40/40 healthy
Proxy Status:            OK, ip 10.244.x.x, 0 redirects active on ports 10256
Cluster health:          8/8 reachable   (2024-xx-xxTxx:xx:xxZ)
```

---

## Common Failure Modes

| Symptom | Likely Cause | Fix |
|---|---|---|
| Cilium pods in `CrashLoopBackOff` | Wrong securityContext for Talos | Review `values.azure-talos.yaml` capabilities |
| `KubeProxyReplacement: False` | `k8sServiceHost` / port not set correctly | Check values.azure-talos.yaml → `k8sServiceHost: 20.120.8.75` |
| Hubble pods crash | Missing relay config | Confirm `hubble.relay.enabled: true` in values.yaml |
| `IPAM:` shows wrong CIDR | values.yaml CIDR mismatch | Check `ipam.operator.clusterPoolIPv4PodCIDRList` in values.yaml |
| Cilium pods `Pending` | Node taints preventing scheduling | Check node taints; Cilium must be able to schedule on all nodes |
| `cgroup: permission denied` | Talos cgroup automount conflict | Confirm `cgroup.autoMountCgroupfs: false` in values.azure-talos.yaml |

For deeper troubleshooting, see [docs/runbooks/support-bundle.md](support-bundle.md).
