# Runbook: Node Scaling via Omni

**Initiative:** azure talos omni backbase dev
**Author:** Julio Garcia

---

## Purpose

Procedure for scaling worker nodes in the `talos-omni-backbase-dev` cluster. All scaling is performed through **Omni** — not through `talosctl` or `kubectl` directly.

---

## Critical Rules

1. **Never use `talosctl` for scaling.** Omni owns machine lifecycle. Direct `talosctl` operations will create config divergence and break Omni reconciliation.
2. **Never add workers until all control plane nodes are Ready.** Degraded control planes cause cascading worker join failures. Verify CP health first, every time.
3. **Always use the Omni-generated Azure image** for new VMs. Generic Talos images from siderolabs/talos releases will not register with this Omni instance.

---

## Pre-Scaling Checklist

Before adding any workers:

- [ ] All 3 control plane nodes show `Ready` in `kubectl get nodes`
- [ ] etcd is healthy
  ```bash
  # Pick any CP node name from kubectl get nodes
  kubectl -n kube-system exec -it etcd-<cp-node> -- \
    etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert /etc/kubernetes/pki/etcd/ca.crt \
    --cert /etc/kubernetes/pki/etcd/server.crt \
    --key /etc/kubernetes/pki/etcd/server.key \
    endpoint health
  ```
- [ ] Cilium is installed and all existing nodes are healthy
  ```bash
  make validate
  ```
- [ ] No pending Omni lifecycle operations on existing nodes

---

## Adding a Worker Node

### Step 1 — Provision an Azure VM with the Omni-generated image

New Azure VMs **must** use the Omni-generated image for this instance (`bellyupdown`).

To get the current Omni installation media:
1. Go to [Omni cluster page](https://bellyupdown.na-west-1.omni.siderolabs.io/clusters)
2. Navigate to **Installation Media** or the image generation section
3. Select **Azure** as the platform
4. Download the customized Azure image or use the SideroLink-embedded VHD already uploaded

> The Omni-generated image contains the SideroLink agent and join token for this specific Omni instance. VMs provisioned with this image phone home to Omni automatically on first boot.

Provision the VM in the worker subnet:
```bash
# Reference — adapt resource names as needed
# VM must be in worker-subnet (10.0.2.0/24) in base-dojo-rg
az vm create \
  --resource-group base-dojo-rg \
  --name <new-worker-name> \
  --location eastus \
  --image <omni-generated-image-name> \
  --size <vm-size> \
  --subnet worker-subnet \
  --vnet-name talos-vnet \
  --nsg "" \
  --no-wait
```

> Adjust `--size` to match the existing worker VM SKU. Confirm the image name from the Omni-generated Azure image you have registered in Azure.

### Step 2 — Wait for machine to appear in Omni

The new VM will boot and register with Omni automatically. This typically takes 2–5 minutes.

1. Go to [Omni cluster page](https://bellyupdown.na-west-1.omni.siderolabs.io/clusters)
2. Navigate to **Machines** or the unallocated machines list
3. Confirm the new machine appears with a registered status

### Step 3 — Assign the machine to the cluster as a worker

In Omni UI:
1. Select the unallocated machine
2. Assign it to cluster `talos-omni-backbase-dev`
3. Set the role: **Worker**
4. Omni will apply the machine config and initiate the join process

### Step 4 — Monitor join progress

In Omni UI: watch the machine status transition from `Registered` → `Configuring` → `Running`.

In kubectl:
```bash
# Watch for new node to appear
kubectl get nodes -w
```

Expected: new node appears as `NotReady` first (Cilium is being configured on it), then transitions to `Ready` within 1–3 minutes.

### Step 5 — Validate post-scaling

```bash
# Confirm new node is Ready
kubectl get nodes

# Confirm Cilium DaemonSet now includes the new node
kubectl -n kube-system get ds cilium
# DESIRED count should have increased by 1

# Run full validation
make validate
```

---

## Removing a Worker Node

### Step 1 — Cordon and drain the node

```bash
NODE_NAME=<node-to-remove>

# Cordon: prevent new pods from scheduling on this node
kubectl cordon "${NODE_NAME}"

# Drain: evict all pods (respects PodDisruptionBudgets)
kubectl drain "${NODE_NAME}" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=5m
```

### Step 2 — Remove the machine from Omni

1. Go to [Omni cluster page](https://bellyupdown.na-west-1.omni.siderolabs.io/clusters)
2. Locate the machine in the cluster's machine list
3. Remove/unallocate the machine from the cluster
4. Omni will reset the machine config and remove it from the Kubernetes cluster

### Step 3 — Delete the Azure VM

After Omni has removed the machine from the cluster:
```bash
az vm delete --resource-group base-dojo-rg --name <vm-name> --yes
```

Also clean up the associated NIC, disk, and public IP if applicable.

### Step 4 — Confirm removal

```bash
# Node should no longer appear
kubectl get nodes

# Validate remaining cluster
make validate
```

---

## Target Cluster Shape

| Role | Current | Target |
|---|---|---|
| Control plane | 3 | 3 (do not change without planning) |
| Workers | variable | 5 (goal state) |

Control plane scaling requires additional planning. Do not add or remove control plane nodes without a full runbook review — etcd quorum changes are high-risk operations.
