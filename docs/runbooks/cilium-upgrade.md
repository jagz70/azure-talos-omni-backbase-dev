# Runbook: Isovalent Enterprise for Cilium — Upgrade

**Initiative:** azure talos omni backbase dev
**Author:** Julio Garcia

---

## Purpose

Safe in-place upgrade of Isovalent Enterprise for Cilium using `helm upgrade`. This runbook covers planning, execution, validation, and rollback triggers.

---

## Upgrade Philosophy

- Helm manages the upgrade lifecycle. Do not manually edit DaemonSet or Deployment specs.
- All value changes go through the values files in `helm/isovalent-enterprise/`. Do not use `--set` flags in ad hoc commands — they create drift from the committed state.
- Always validate before and after.
- Keep the prior Helm release revision available for rollback.
- Upgrades should be done during a maintenance window or low-traffic period.

---

## Pre-Upgrade Checklist

- [ ] Read the Isovalent Enterprise v25.11 release notes for the target version
  - Review for breaking changes, deprecated values, new required fields
- [ ] Confirm the new chart version is available in the Helm repo
  ```bash
  helm search repo isovalent/cilium --versions | head -20
  ```
- [ ] Cluster is healthy before upgrade — run full validation
  ```bash
  make validate
  ```
- [ ] All nodes are Ready
  ```bash
  kubectl get nodes
  ```
- [ ] No ongoing Omni lifecycle operations (scaling, OS upgrade) — check Omni UI
- [ ] Update `ISOVALENT_VERSION` in `.env` to the new target version
- [ ] Review diff between current and new values (if any values file changes are needed)
  ```bash
  make helm-diff   # requires helm-diff plugin
  ```
- [ ] Record the current Helm revision for rollback reference
  ```bash
  helm history cilium -n kube-system
  ```

---

## Upgrade Steps

### Step 1 — Update .env

Set the new chart version:
```bash
# In .env:
ISOVALENT_VERSION=<new-version>
```

### Step 2 — Update values files if needed

If the new release requires new or changed Helm values, update:
- `helm/isovalent-enterprise/values.yaml`
- `helm/isovalent-enterprise/values.azure-talos.yaml`

Commit value changes to Git before running the upgrade:
```bash
git add helm/isovalent-enterprise/
git commit -m "Upgrade Isovalent Enterprise to <new-version> — update Helm values"
git push
```

### Step 3 — Run upgrade

```bash
make upgrade
```

`make upgrade` runs:
```bash
helm upgrade cilium isovalent/cilium \
  --namespace kube-system \
  --version "${ISOVALENT_VERSION}" \
  --values helm/isovalent-enterprise/values.yaml \
  --values helm/isovalent-enterprise/values.azure-talos.yaml \
  --reuse-values \
  --atomic \
  --timeout 10m \
  --wait
```

The `--atomic` flag means: if the upgrade fails or times out, Helm automatically rolls back to the previous release. You will see the rollback happen in the output.

Expected duration: 5–15 minutes depending on node count and image pull speed.

### Step 4 — Validate

```bash
make validate
```

All checks must pass. If any checks fail, trigger a manual rollback:
```bash
make rollback-help
```

---

## What Happens During Upgrade

1. Helm applies the new chart to the cluster
2. Cilium operator is upgraded first (Deployment rolling update)
3. Cilium agent DaemonSet is updated (rolling update, one node at a time)
4. Hubble relay and UI are updated (Deployment rolling updates)
5. Each pod is replaced in sequence; existing pods continue to serve traffic until the new pod is Ready
6. kube-proxy replacement remains active throughout — no service disruption expected

Nodes briefly have a mix of old and new Cilium versions during the rolling update. This is expected and handled by Cilium's upgrade compatibility guarantees.

---

## Upgrade Rollback Trigger

Trigger a manual rollback if:
- `make validate` reports failures after upgrade
- Pod networking is disrupted (pods cannot reach each other or DNS fails)
- Cilium pods are in `CrashLoopBackOff` after upgrade

See [cilium-rollback.md](cilium-rollback.md) for the rollback procedure.

---

## Post-Upgrade

After a successful upgrade:

1. Confirm all nodes are Ready: `kubectl get nodes`
2. Confirm Hubble flows are visible: `make hubble`
3. Record the new Helm revision: `helm history cilium -n kube-system`
4. Update any documentation that references the previous version
5. If values files were changed, confirm they are committed and pushed
