# Lessons Learned: Azure + Talos + Omni Build

**Initiative:** azure talos omni backbase dev
**Author:** Julio Garcia

This document captures hard-won lessons from the initial build of this cluster. These are real failures and their fixes — not hypothetical guidance. Future operators must internalize these before performing any infrastructure work on this initiative.

---

## Lesson 1: Omni Owns Lifecycle — Do Not Use Standalone Talos Flows

**What happened:**
Early attempts used `talosctl gen config`, `talosctl apply-config`, and `talosctl bootstrap` as the primary cluster setup path — the standard workflow documented in the upstream Talos documentation.

**Why it failed:**
This cluster is Omni-managed. Omni generates and owns machine configs. Running standalone `talosctl` commands creates config divergence and conflicts with Omni's management plane. Omni was unable to reconcile the cluster state after manual `talosctl` operations were applied.

**The fix:**
Stop all standalone `talosctl` operations. Let Omni own the full lifecycle. Use Omni UI for cluster creation, machine assignment, and config application.

**Rule:**
Never run `talosctl gen config`, `talosctl apply-config`, or `talosctl bootstrap` for this cluster. Omni owns lifecycle.

---

## Lesson 2: Use Omni-Generated Azure Images — Not Generic Talos Images

**What happened:**
Initial VMs were provisioned using the generic Talos Azure VHD image from `https://github.com/siderolabs/talos/releases`. VMs booted successfully but never appeared in the Omni machine list.

**Why it failed:**
Generic Talos images do not include SideroLink agent configuration or the Omni join token. The machine has no way to phone home to the Omni instance.

**The fix:**
Generate the Azure image from the Omni UI using the **Installation Media** or **Download** feature for the specific Omni instance (`bellyupdown`). This generates a customized image with the embedded SideroLink endpoint and join token. VMs provisioned with this image register with Omni automatically on first boot.

**Rule:**
Always use the Omni-generated image for Azure VMs. The standard Talos release images will not work with Omni.

---

## Lesson 3: AZURE_STORAGE_AUTH_MODE=login Breaks Blob Upload

**What happened:**
VHD upload to Azure Blob Storage consistently failed with authorization errors, even though `az login` was successful and the storage account existed.

**Why it failed:**
The shell environment had `AZURE_STORAGE_AUTH_MODE=login` set from a prior session or profile. This mode requires Azure AD token-based authentication for every storage operation. The token scope or timing caused the blob upload to fail with authorization errors despite the login appearing valid.

**The fix:**
```bash
unset AZURE_STORAGE_AUTH_MODE
```
Then use the storage account connection-string authentication method instead of `--auth-mode login` for blob upload operations.

**Rule:**
Before running any `az storage blob upload` command, unset `AZURE_STORAGE_AUTH_MODE`. Use connection-string auth for blob operations.

---

## Lesson 4: Eastern Bank Azure Policy Enforces TLS 1.2 Minimum

**What happened:**
`az storage account create` failed with a policy violation error.

**Why it failed:**
Eastern Bank's Azure tenant enforces a policy requiring storage accounts to use TLS 1.2 as the minimum version. The default Azure CLI command does not explicitly set the TLS minimum version, and the policy blocks accounts created without it.

**The fix:**
Add `--min-tls-version TLS1_2` to all `az storage account create` commands:
```bash
az storage account create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${STORAGE_ACCOUNT}" \
  --location "${LOCATION}" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --https-only true
```

**Rule:**
All storage account creation commands must include `--min-tls-version TLS1_2`. This is a tenant-level policy requirement, not optional.

---

## Lesson 5: Azure VHD Upload Requires Page Blob Mode

**What happened:**
VHD upload succeeded with `az storage blob upload` but Azure rejected the blob when creating a managed image from it.

**Why it failed:**
Azure managed images sourced from VHD blobs require the blob to be stored as a **page blob**. The default `az storage blob upload` creates a block blob. Block blobs cannot be used as VHD sources for Azure managed images.

**The fix:**
```bash
az storage blob upload \
  --account-name "${STORAGE_ACCOUNT}" \
  --container-name "${CONTAINER_NAME}" \
  --name "${BLOB_NAME}" \
  --file "${VHD_FILE}" \
  --type page \
  --overwrite true
```

**Rule:**
Always use `--type page` when uploading VHD files to Azure Blob Storage for use as managed image sources.

---

## Lesson 6: Do Not Add Workers Until the Control Plane Is Healthy

**What happened:**
Workers were added to Omni before all control plane nodes were fully healthy. This caused workers to fail to join and created compounding errors across both control plane and worker reconciliation.

**Why it failed:**
The Kubernetes API server and etcd cluster must be stable before worker nodes attempt to join. Adding workers to a degraded control plane results in failed CSR approvals, kubelet config distribution failures, and difficult-to-debug node registration errors.

**The fix:**
Before adding any workers:
1. Confirm all 3 control plane nodes show `Ready` status in `kubectl get nodes`
2. Confirm etcd is healthy: `kubectl -n kube-system exec -it etcd-<cp-node> -- etcdctl endpoint health`
3. Confirm all kube-system pods are running
Only then add workers via Omni.

**Rule:**
Fix the control plane completely before scaling workers. This order is non-negotiable.

---

## Lesson 7: Kubeconfig Must Come From Omni

**What happened:**
An attempt was made to generate a kubeconfig using `talosctl kubeconfig`. This resulted in a kubeconfig that worked briefly but became stale and caused auth failures after Omni reconciled the cluster.

**Why it failed:**
Omni manages the cluster's PKI and certificate authority. Kubeconfigs generated outside of Omni may use a different CA or expiry model than what Omni expects, leading to certificate validation failures.

**The fix:**
Download the kubeconfig exclusively from the Omni UI:
1. Go to https://bellyupdown.na-west-1.omni.siderolabs.io/clusters
2. Select `talos-omni-backbase-dev`
3. Use the kubeconfig download option

**Rule:**
Never generate or distribute kubeconfigs independently of Omni. Always use the Omni-provided kubeconfig.

---

## Summary Table

| # | Lesson | Impact | Fix |
|---|---|---|---|
| 1 | Standalone Talos lifecycle breaks Omni | Cluster unmanageable | Use Omni for all lifecycle ops |
| 2 | Generic Talos images don't register with Omni | VMs never appear in Omni | Use Omni-generated image only |
| 3 | AZURE_STORAGE_AUTH_MODE=login breaks upload | Blob upload fails | Unset var, use connection-string auth |
| 4 | TLS 1.2 policy on storage accounts | Storage account creation fails | Add --min-tls-version TLS1_2 |
| 5 | VHD must be page blob | Managed image creation fails | Use --type page |
| 6 | Adding workers before CP is healthy | Node join failures cascade | Verify CP fully healthy first |
| 7 | Kubeconfig outside Omni becomes stale | Auth failures | Use Omni kubeconfig only |
