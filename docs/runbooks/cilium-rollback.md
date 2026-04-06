# Runbook: Isovalent Enterprise for Cilium — Rollback

**Initiative:** azure talos omni backbase dev
**Author:** Julio Garcia

---

## Purpose

Procedure for rolling back Isovalent Enterprise for Cilium to a previous Helm release revision after a failed or problematic upgrade.

---

## When to Roll Back

Trigger a rollback if any of the following are true after an upgrade:
- `make validate` reports `FAIL` on critical checks
- Pods cannot reach each other (pod-to-pod connectivity broken)
- DNS resolution fails across the cluster
- Cilium DaemonSet pods are in `CrashLoopBackOff` and do not recover
- Hubble is non-functional and the issue is not explained by a known transient startup delay
- `cilium status` reports `KubeProxyReplacement: False` after a previously working upgrade

Do **not** rollback for:
- Transient `Pending` pod states during a rolling update (wait for it to complete)
- Warnings in `cilium status` that are not impacting traffic
- Hubble relay startup delay (give it 2–3 minutes after DaemonSet rollout completes)

---

## Rollback Steps

### Step 1 — Check release history

```bash
helm history cilium -n kube-system
```

Output example:
```
REVISION  UPDATED                   STATUS      CHART            APP VERSION  DESCRIPTION
1         2025-11-01 10:00:00 UTC   superseded  cilium-1.16.5    1.16.5       Install complete
2         2025-11-15 14:00:00 UTC   deployed    cilium-1.16.7    1.16.7       Upgrade complete
```

Identify the last known good revision (e.g., revision `1`).

### Step 2 — Roll back to the previous revision

Roll back to the immediately prior revision:
```bash
helm rollback cilium -n kube-system --wait
```

Roll back to a specific revision:
```bash
helm rollback cilium <revision> -n kube-system --wait
```

`--wait` blocks until all pods are Ready or the rollback fails.

Expected duration: 3–8 minutes.

### Step 3 — Verify rollback succeeded

```bash
helm history cilium -n kube-system
# The latest entry should show STATUS: deployed and the prior chart version

helm status cilium -n kube-system
# STATUS: deployed
```

### Step 4 — Validate the cluster

```bash
make validate
```

All checks must pass. If they do not, the issue may be pre-existing and unrelated to the upgrade.

### Step 5 — Update .env

Reset `ISOVALENT_VERSION` in `.env` back to the previously working version to prevent accidental re-upgrade:
```bash
# In .env:
ISOVALENT_VERSION=<prior-working-version>
```

---

## If Rollback Itself Fails

If `helm rollback` fails (e.g., Helm state is inconsistent):

1. Check Helm release status:
   ```bash
   helm status cilium -n kube-system
   ```

2. If status is `failed` or `pending-upgrade`, attempt a direct install over the release:
   ```bash
   helm upgrade --install cilium isovalent/cilium \
     --namespace kube-system \
     --version "<last-known-good-version>" \
     --values helm/isovalent-enterprise/values.yaml \
     --values helm/isovalent-enterprise/values.azure-talos.yaml \
     --force \
     --atomic \
     --timeout 10m \
     --wait
   ```

3. If the cluster networking is fully broken (nodes cannot communicate):
   - This is a critical incident — escalate to Isovalent enterprise support
   - Collect a support bundle before attempting further changes (see [support-bundle.md](support-bundle.md))
   - Do NOT delete and reinstall Cilium without guidance — this will disrupt all pod networking

---

## After Rollback

1. Investigate the cause of the failed upgrade before attempting it again
2. Check Cilium pod logs from the failed upgrade:
   ```bash
   kubectl -n kube-system logs -l k8s-app=cilium --previous --tail=100
   ```
3. Check Helm upgrade events:
   ```bash
   kubectl -n kube-system get events --sort-by='.lastTimestamp' | tail -30
   ```
4. Review Isovalent release notes for the version that failed — look for breaking changes or new required values
5. Update `helm/isovalent-enterprise/values.yaml` or `values.azure-talos.yaml` as needed before retrying
6. Commit any values changes before attempting the upgrade again
