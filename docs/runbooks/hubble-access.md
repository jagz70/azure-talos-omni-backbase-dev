# Runbook: Hubble UI and CLI Access

**Initiative:** azure talos omni backbase dev
**Author:** Julio Garcia

---

## Purpose

Procedures for accessing Hubble observability — both the browser-based UI and the command-line interface. Hubble provides real-time L3/L4/L7 network flow visibility for all Cilium-managed workloads.

---

## Hubble UI

### Access via port-forward (standard method)

```bash
make hubble
```

This runs `scripts/hubble-port-forward.sh`, which port-forwards the `hubble-ui` service to `http://localhost:12000`.

Manual equivalent:
```bash
kubectl port-forward -n kube-system service/hubble-ui 12000:12000
```

Open in browser: **http://localhost:12000**

### What the Hubble UI shows

- **Namespace view:** select a namespace to see all pod-to-pod flows in real time
- **Flow table:** L3/L4/L7 flows with source, destination, verdict (forwarded/dropped)
- **Service map:** visual topology of communication between workloads
- **Filtering:** filter by namespace, pod label, destination port, protocol, verdict

### Useful UI filters

| Goal | Filter |
|---|---|
| Show only dropped flows | Verdict = Dropped |
| Show flows to a specific pod | To: pod name |
| Show HTTP flows | Protocol = HTTP |
| Show DNS flows | Port = 53 |

---

## Hubble CLI

Two methods are available. Method A (pod exec) requires no local binary. Method B (local binary) provides a better interactive experience.

---

### Method A: Hubble CLI via kubectl exec (no local binary required)

Run Hubble observe commands directly from inside a Cilium pod:

```bash
# Open an interactive session
kubectl -n kube-system exec -it ds/cilium -- bash

# Inside the pod:
hubble observe
hubble observe --last 50
hubble observe --namespace default
hubble observe --type drop
hubble observe --verdict DROPPED
hubble observe --from-pod default/my-pod
hubble observe --to-pod default/my-service
hubble observe --protocol http
hubble status
```

Non-interactive (single command):
```bash
kubectl -n kube-system exec -it ds/cilium -- hubble observe --last 20
kubectl -n kube-system exec -it ds/cilium -- hubble observe --verdict DROPPED --last 50
kubectl -n kube-system exec -it ds/cilium -- hubble status
```

---

### Method B: Local hubble binary + relay port-forward

This method gives access to flows from all nodes (not just the node the exec'd pod is on), and provides a better interactive CLI experience.

#### Install hubble CLI

```bash
# macOS
HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
curl -L --fail --remote-name-all \
  "https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-darwin-amd64.tar.gz"
tar xzvf hubble-darwin-amd64.tar.gz
sudo mv hubble /usr/local/bin/
rm hubble-darwin-amd64.tar.gz
hubble version
```

> Note: for Isovalent Enterprise, verify whether a specific Hubble CLI version is recommended
> in your Isovalent customer portal. The upstream hubble CLI is generally compatible.

#### Port-forward the Hubble relay

In a separate terminal:
```bash
kubectl port-forward -n kube-system service/hubble-relay 4245:80
```

#### Query flows

```bash
# Set relay address
export HUBBLE_SERVER=localhost:4245

# Status check
hubble status

# Last 20 flows across all nodes
hubble observe --last 20

# Watch live flows
hubble observe --follow

# Filter to a namespace
hubble observe --namespace default --follow

# Show only dropped flows
hubble observe --verdict DROPPED --follow

# Show flows from a specific pod
hubble observe --from-pod default/frontend --follow

# Show HTTP flows with URL
hubble observe --protocol http --http-url "/" --follow

# Show DNS queries
hubble observe --protocol dns --follow

# Count flows by destination port (last 1000)
hubble observe --last 1000 -o json | jq '.flow.l4.TCP.destination_port // .flow.l4.UDP.destination_port' | sort | uniq -c | sort -rn | head -20
```

---

## Flow Verdicts Reference

| Verdict | Meaning |
|---|---|
| `FORWARDED` | Flow was allowed and forwarded |
| `DROPPED` | Flow was dropped (by network policy or Cilium) |
| `ERROR` | Flow processing error |
| `AUDIT` | Flow was allowed in audit mode (policy is in observe mode) |
| `REDIRECTED` | Flow was redirected (e.g., to a proxy) |

---

## Hubble Metrics (Future)

When Prometheus is available in the cluster, Hubble metrics can be enabled by updating `values.yaml`:

```yaml
hubble:
  metrics:
    enabled:
      - dns
      - drop
      - tcp
      - flow
      - port-distribution
      - icmp
      - http
```

Then update the Helm release:
```bash
make upgrade
```

See `docs/architecture/network-design.md` for the Prometheus integration track (Phase 4).

---

## Troubleshooting Hubble

| Symptom | Check |
|---|---|
| UI loads but shows no flows | Hubble relay may be starting — wait 2–3 minutes |
| `hubble status` returns "failed to connect" | Confirm port-forward is running on port 4245 |
| Relay pods crash on startup | Check `kubectl -n kube-system logs -l k8s-app=hubble-relay` |
| UI shows "Unable to connect to Hubble relay" | Confirm `hubble-relay` service exists and pods are Running |
| Only seeing local-node flows via exec | Use Method B (local binary + relay port-forward) for cluster-wide flows |
