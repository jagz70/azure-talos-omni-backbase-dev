# Runbook: Support Bundle Collection

**Initiative:** azure talos omni backbase dev
**Author:** Julio Garcia

---

## Purpose

Procedures for collecting diagnostic information for Isovalent Enterprise support cases. Collect a support bundle before escalating any Cilium issue to Isovalent.

---

## When to Collect a Support Bundle

- Cilium pods are crashing and logs alone are insufficient
- Network connectivity issues are occurring and the root cause is unclear
- An upgrade failed and the rollback did not fully restore health
- Opening an Isovalent enterprise support ticket

---

## Method 1: cilium-sysdump (Recommended)

`cilium-sysdump` collects comprehensive diagnostic data from the cluster:
- Cilium pod logs (current and previous)
- DaemonSet, Deployment, and ConfigMap manifests
- Cilium endpoint states
- Hubble flow data
- Node information and kernel versions
- Network policy state
- BPF maps and program state

### Install cilium CLI (needed for sysdump)

```bash
# macOS
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all \
  "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-darwin-amd64.tar.gz"
tar xzvf cilium-darwin-amd64.tar.gz
sudo mv cilium /usr/local/bin/cilium-cli
rm cilium-darwin-amd64.tar.gz
cilium-cli version
```

> For Isovalent Enterprise, confirm whether a specific cilium CLI version is required
> by checking your Isovalent customer portal.

### Collect the sysdump

```bash
# Basic collection (adjust kubeconfig path from your .env)
export KUBECONFIG=/path/to/talos-omni-backbase-dev-kubeconfig.yaml

cilium-cli sysdump \
  --output-filename cilium-sysdump-$(date +%Y%m%d-%H%M%S)
```

With additional options for deeper collection:
```bash
cilium-cli sysdump \
  --output-filename cilium-sysdump-$(date +%Y%m%d-%H%M%S) \
  --node-list <comma-separated-node-names>   # limit to affected nodes if known
```

This produces a `.zip` file in the current directory.

---

## Method 2: Manual Log Collection

If `cilium-cli` is unavailable, collect logs manually.

```bash
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BUNDLE_DIR="support-bundle-${TIMESTAMP}"
mkdir -p "${BUNDLE_DIR}"

# Cilium pod logs (all nodes)
kubectl -n kube-system logs -l k8s-app=cilium --prefix > "${BUNDLE_DIR}/cilium-pods.log" 2>&1
kubectl -n kube-system logs -l k8s-app=cilium --previous --prefix > "${BUNDLE_DIR}/cilium-pods-previous.log" 2>&1

# Cilium operator logs
kubectl -n kube-system logs -l name=cilium-operator --prefix > "${BUNDLE_DIR}/cilium-operator.log" 2>&1

# Hubble relay logs
kubectl -n kube-system logs -l k8s-app=hubble-relay --prefix > "${BUNDLE_DIR}/hubble-relay.log" 2>&1

# Cilium status from one node
CILIUM_POD=$(kubectl -n kube-system get pods -l k8s-app=cilium -o name | head -1)
kubectl -n kube-system exec "${CILIUM_POD}" -- cilium status > "${BUNDLE_DIR}/cilium-status.txt" 2>&1
kubectl -n kube-system exec "${CILIUM_POD}" -- cilium endpoint list > "${BUNDLE_DIR}/cilium-endpoints.txt" 2>&1
kubectl -n kube-system exec "${CILIUM_POD}" -- cilium service list > "${BUNDLE_DIR}/cilium-services.txt" 2>&1
kubectl -n kube-system exec "${CILIUM_POD}" -- cilium bpf lb list > "${BUNDLE_DIR}/cilium-bpf-lb.txt" 2>&1

# Node and pod state
kubectl get nodes -o wide > "${BUNDLE_DIR}/nodes.txt" 2>&1
kubectl -n kube-system get pods -o wide > "${BUNDLE_DIR}/kube-system-pods.txt" 2>&1
kubectl -n kube-system get events --sort-by='.lastTimestamp' > "${BUNDLE_DIR}/events.txt" 2>&1

# Helm release info
helm status cilium -n kube-system > "${BUNDLE_DIR}/helm-status.txt" 2>&1
helm get values cilium -n kube-system > "${BUNDLE_DIR}/helm-values.txt" 2>&1
helm history cilium -n kube-system > "${BUNDLE_DIR}/helm-history.txt" 2>&1

# Compress
tar czf "${BUNDLE_DIR}.tar.gz" "${BUNDLE_DIR}/"
rm -rf "${BUNDLE_DIR}"
echo "Bundle created: ${BUNDLE_DIR}.tar.gz"
```

---

## What to Include in an Isovalent Support Ticket

When opening a support ticket, provide:

1. **Support bundle** (`cilium-sysdump-*.zip` or the manual bundle `tar.gz`)
2. **Cluster context:**
   - Kubernetes version: `kubectl version`
   - Cilium/Isovalent version: `helm get values cilium -n kube-system | grep version`
   - Platform: Azure, Talos Linux, Omni-managed
3. **Problem statement:**
   - What is broken
   - When it started
   - What changed immediately before (upgrade, scaling, config change)
4. **Steps already taken** (rollback attempts, config changes)
5. **Impact:** which workloads or namespaces are affected

---

## Omni-Specific Context for Support

When working with Sidero Labs support on Talos/Omni issues (as opposed to Cilium issues):

- Omni instance: `bellyupdown.na-west-1.omni.siderolabs.io`
- Cluster name: `talos-omni-backbase-dev`
- Provide the machine serial numbers from the Omni UI for any affected nodes
- Do not provide the Omni join token or kubeconfig externally — these are sensitive credentials

---

## Support Bundle Security

The support bundle may contain:
- Pod names and IP addresses (internal)
- Network flow metadata
- Kubernetes resource names

The bundle does **not** contain:
- Application data or payload content
- Secrets or ConfigMap values
- kubeconfig or credentials

Review the bundle before sharing if there are internal naming conventions or IP ranges that should not leave the organization. Use Isovalent's secure upload channel if available.
