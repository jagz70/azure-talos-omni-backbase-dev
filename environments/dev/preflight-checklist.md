# Pre-Installation Checklist: Isovalent Enterprise for Cilium

**Environment:** dev (talos-omni-backbase-dev)
**Author:** Julio Garcia

Complete this checklist before running `make install`. Each item must be confirmed.

---

## 1. Omni Cluster Health

- [ ] Log in to Omni: https://bellyupdown.na-west-1.omni.siderolabs.io/clusters
- [ ] Cluster `talos-omni-backbase-dev` shows healthy
- [ ] All 3 control plane nodes show status **Ready**
- [ ] No control plane nodes are in a degraded or unknown state
- [ ] `kubectl get nodes` returns all expected nodes
- [ ] No nodes show `NotReady`

**Do not proceed if any control plane node is not Ready.**

---

## 2. Kubernetes Cluster Access

- [ ] kubeconfig downloaded from Omni (not generated independently)
- [ ] `KUBECONFIG` path set correctly in `.env`
- [ ] `kubectl cluster-info` returns the correct API endpoint (`https://20.120.8.75:6443`)
- [ ] `kubectl get namespaces` returns successfully

---

## 3. No Existing CNI

- [ ] No existing CNI DaemonSet is running in `kube-system`
  ```bash
  kubectl -n kube-system get ds | grep -i cni
  ```
- [ ] No existing Cilium or Calico pods running
- [ ] `kube-proxy` is NOT running (Talos with Omni CNI=none disables it)
  ```bash
  kubectl -n kube-system get ds kube-proxy 2>&1
  # Expected: "Error from server (NotFound)"
  ```

---

## 4. Local Tooling

- [ ] `kubectl` installed and working
- [ ] `helm` >= 3.12 installed
  ```bash
  helm version
  ```
- [ ] `az` CLI authenticated
  ```bash
  az account show
  ```

---

## 5. Isovalent Enterprise Inputs

- [ ] `.env` file exists (copied from `.env.example`)
- [ ] `ISOVALENT_HELM_REPO` is set
- [ ] `ISOVALENT_VERSION` is set to the exact chart version for v25.11
- [ ] Isovalent Helm repo credentials are populated IF required by your customer portal
- [ ] `helm repo add` test passes:
  ```bash
  make helm-repo-add
  ```
- [ ] The chart version is listed in repo:
  ```bash
  helm search repo isovalent/cilium --versions | head -10
  ```

---

## 6. Network Verification

- [ ] Pod CIDR `10.244.0.0/16` does not conflict with Azure VNET `10.0.0.0/16`
- [ ] Service CIDR `10.96.0.0/12` does not conflict with Azure VNET
- [ ] Azure LB IP `20.120.8.75` is reachable on port 6443 from your workstation

---

## 7. Preflight Script

- [ ] `make preflight` completes with no errors

---

## Sign-off

| Check | Status | Notes |
|---|---|---|
| Omni cluster health | | |
| Kubernetes access | | |
| No existing CNI | | |
| Local tooling | | |
| Isovalent inputs | | |
| Network verification | | |
| Preflight script | | |

Operator: ___________________________  Date: _______________
