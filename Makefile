# azure-talos-omni-backbase-dev
# Makefile — deterministic command surface for Isovalent Enterprise for Cilium operations
# Author: Julio Garcia

SHELL := /bin/bash
.DEFAULT_GOAL := help

ENV_FILE ?= .env
ENV_EXISTS := $(shell test -f $(ENV_FILE) && echo yes || echo no)

# Load .env if present
ifeq ($(ENV_EXISTS),yes)
  include $(ENV_FILE)
  export
endif

HELM_NAMESPACE   ?= kube-system
HELM_RELEASE     ?= cilium
HELM_CHART       ?= isovalent/cilium
HELM_VALUES      := helm/isovalent-enterprise/values.yaml
HELM_VALUES_ENV  := helm/isovalent-enterprise/values.azure-talos.yaml
SCRIPTS_DIR      := scripts

# ─── Help ────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "azure-talos-omni-backbase-dev — Isovalent Enterprise for Cilium"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ─── Environment ─────────────────────────────────────────────────────────────

.PHONY: env-check
env-check: ## Verify .env is present and key variables are set
	@echo "==> Checking .env..."
	@[ "$(ENV_EXISTS)" = "yes" ] || (echo "ERROR: .env not found. Copy .env.example and populate it." && exit 1)
	@[ -n "$(KUBECONFIG)" ] || (echo "ERROR: KUBECONFIG is not set in .env" && exit 1)
	@[ -n "$(CLUSTER_API_ENDPOINT)" ] || (echo "ERROR: CLUSTER_API_ENDPOINT is not set in .env" && exit 1)
	@echo "    .env: OK"
	@echo "    KUBECONFIG: $(KUBECONFIG)"
	@echo "    CLUSTER_API_ENDPOINT: $(CLUSTER_API_ENDPOINT)"

# ─── Preflight ───────────────────────────────────────────────────────────────

.PHONY: preflight
preflight: env-check ## Run pre-installation checks
	@bash $(SCRIPTS_DIR)/preflight.sh

# ─── Install ─────────────────────────────────────────────────────────────────

.PHONY: helm-repo-add
helm-repo-add: ## Add the Isovalent Helm repository
	@echo "==> Adding Isovalent Helm repo..."
	@if [ -n "$(ISOVALENT_HELM_USERNAME)" ] && [ -n "$(ISOVALENT_HELM_TOKEN)" ]; then \
		helm repo add isovalent $(ISOVALENT_HELM_REPO) \
			--username "$(ISOVALENT_HELM_USERNAME)" \
			--password "$(ISOVALENT_HELM_TOKEN)" \
			--force-update; \
	else \
		helm repo add isovalent $(ISOVALENT_HELM_REPO) --force-update; \
	fi
	@helm repo update isovalent
	@echo "    Helm repo: OK"

.PHONY: install
install: preflight helm-repo-add ## Install Isovalent Enterprise for Cilium via Helm
	@bash $(SCRIPTS_DIR)/install-cilium.sh

# ─── Upgrade ─────────────────────────────────────────────────────────────────

.PHONY: upgrade
upgrade: env-check helm-repo-add ## Upgrade Isovalent Enterprise in place
	@echo "==> Upgrading $(HELM_RELEASE) in namespace $(HELM_NAMESPACE)..."
	@helm upgrade $(HELM_RELEASE) $(HELM_CHART) \
		--namespace $(HELM_NAMESPACE) \
		--version "$(ISOVALENT_VERSION)" \
		--values $(HELM_VALUES) \
		--values $(HELM_VALUES_ENV) \
		--reuse-values \
		--atomic \
		--timeout 10m \
		--wait
	@echo "==> Upgrade complete."

# ─── Validate ────────────────────────────────────────────────────────────────

.PHONY: validate
validate: env-check ## Validate Cilium + Hubble installation health
	@bash $(SCRIPTS_DIR)/validate-cilium.sh

.PHONY: status
status: env-check ## Show Cilium pod and node status (quick view)
	@echo "==> Cilium pods:"
	@kubectl -n $(HELM_NAMESPACE) get pods -l app.kubernetes.io/part-of=cilium -o wide
	@echo ""
	@echo "==> Cilium node status:"
	@kubectl -n $(HELM_NAMESPACE) exec -it ds/cilium -- cilium status --brief 2>/dev/null || \
		kubectl -n $(HELM_NAMESPACE) get ds cilium -o wide

# ─── Hubble ──────────────────────────────────────────────────────────────────

.PHONY: hubble
hubble: env-check ## Port-forward Hubble UI to localhost:12000
	@bash $(SCRIPTS_DIR)/hubble-port-forward.sh

# ─── Rollback guidance ───────────────────────────────────────────────────────

.PHONY: rollback-help
rollback-help: ## Print Helm rollback guidance
	@echo ""
	@echo "==> Rollback guidance for $(HELM_RELEASE):"
	@echo ""
	@echo "  1. List Helm release history:"
	@echo "       helm history $(HELM_RELEASE) -n $(HELM_NAMESPACE)"
	@echo ""
	@echo "  2. Roll back to the previous revision:"
	@echo "       helm rollback $(HELM_RELEASE) -n $(HELM_NAMESPACE) --wait"
	@echo ""
	@echo "  3. Roll back to a specific revision (e.g., revision 2):"
	@echo "       helm rollback $(HELM_RELEASE) 2 -n $(HELM_NAMESPACE) --wait"
	@echo ""
	@echo "  4. After rollback, re-run validation:"
	@echo "       make validate"
	@echo ""
	@echo "  See docs/runbooks/cilium-rollback.md for full procedure."
	@echo ""

# ─── Hubble relay port-forward (for local hubble CLI) ────────────────────────

.PHONY: hubble-relay
hubble-relay: env-check ## Port-forward Hubble relay gRPC to localhost:4245 (for hubble CLI)
	@echo "==> Starting Hubble relay port-forward on localhost:4245..."
	@echo "    In another terminal: HUBBLE_SERVER=localhost:4245 hubble observe --follow"
	@echo "    Press Ctrl-C to stop."
	@kubectl port-forward -n $(HELM_NAMESPACE) service/hubble-relay 4245:80

# ─── Logs ────────────────────────────────────────────────────────────────────

.PHONY: logs-cilium
logs-cilium: env-check ## Tail Cilium agent logs across all nodes
	@kubectl -n $(HELM_NAMESPACE) logs -l k8s-app=cilium --prefix --follow --tail=50

.PHONY: logs-operator
logs-operator: env-check ## Tail Cilium operator logs
	@kubectl -n $(HELM_NAMESPACE) logs -l name=cilium-operator --prefix --follow --tail=50

.PHONY: logs-hubble-relay
logs-hubble-relay: env-check ## Tail Hubble relay logs
	@kubectl -n $(HELM_NAMESPACE) logs -l k8s-app=hubble-relay --prefix --follow --tail=50

# ─── Release info ─────────────────────────────────────────────────────────────

.PHONY: helm-values
helm-values: env-check ## Show current deployed Helm values
	@helm get values $(HELM_RELEASE) -n $(HELM_NAMESPACE)

.PHONY: helm-history
helm-history: env-check ## Show Helm release history
	@helm history $(HELM_RELEASE) -n $(HELM_NAMESPACE)

# ─── Support bundle ───────────────────────────────────────────────────────────

.PHONY: support-bundle
support-bundle: env-check ## Collect manual support bundle (logs, status, events)
	@BUNDLE_DIR="support-bundle-$$(date +%Y%m%d-%H%M%S)"; \
	mkdir -p "$$BUNDLE_DIR"; \
	echo "==> Collecting support bundle into $$BUNDLE_DIR ..."; \
	kubectl -n $(HELM_NAMESPACE) logs -l k8s-app=cilium --prefix > "$$BUNDLE_DIR/cilium-pods.log" 2>&1 || true; \
	kubectl -n $(HELM_NAMESPACE) logs -l k8s-app=cilium --previous --prefix > "$$BUNDLE_DIR/cilium-pods-previous.log" 2>&1 || true; \
	kubectl -n $(HELM_NAMESPACE) logs -l name=cilium-operator --prefix > "$$BUNDLE_DIR/cilium-operator.log" 2>&1 || true; \
	kubectl -n $(HELM_NAMESPACE) logs -l k8s-app=hubble-relay --prefix > "$$BUNDLE_DIR/hubble-relay.log" 2>&1 || true; \
	CPOD=$$(kubectl -n $(HELM_NAMESPACE) get pods -l k8s-app=cilium -o name 2>/dev/null | head -1); \
	[ -n "$$CPOD" ] && kubectl -n $(HELM_NAMESPACE) exec "$$CPOD" -- cilium status > "$$BUNDLE_DIR/cilium-status.txt" 2>&1 || true; \
	[ -n "$$CPOD" ] && kubectl -n $(HELM_NAMESPACE) exec "$$CPOD" -- cilium endpoint list > "$$BUNDLE_DIR/cilium-endpoints.txt" 2>&1 || true; \
	[ -n "$$CPOD" ] && kubectl -n $(HELM_NAMESPACE) exec "$$CPOD" -- cilium service list > "$$BUNDLE_DIR/cilium-services.txt" 2>&1 || true; \
	kubectl get nodes -o wide > "$$BUNDLE_DIR/nodes.txt" 2>&1 || true; \
	kubectl -n $(HELM_NAMESPACE) get pods -o wide > "$$BUNDLE_DIR/kube-system-pods.txt" 2>&1 || true; \
	kubectl -n $(HELM_NAMESPACE) get events --sort-by='.lastTimestamp' > "$$BUNDLE_DIR/events.txt" 2>&1 || true; \
	helm status $(HELM_RELEASE) -n $(HELM_NAMESPACE) > "$$BUNDLE_DIR/helm-status.txt" 2>&1 || true; \
	helm get values $(HELM_RELEASE) -n $(HELM_NAMESPACE) > "$$BUNDLE_DIR/helm-values.txt" 2>&1 || true; \
	helm history $(HELM_RELEASE) -n $(HELM_NAMESPACE) > "$$BUNDLE_DIR/helm-history.txt" 2>&1 || true; \
	tar czf "$$BUNDLE_DIR.tar.gz" "$$BUNDLE_DIR/"; \
	rm -rf "$$BUNDLE_DIR"; \
	echo "==> Bundle created: $$BUNDLE_DIR.tar.gz"; \
	echo "    See docs/runbooks/support-bundle.md for Isovalent sysdump instructions."

# ─── Utility ─────────────────────────────────────────────────────────────────

.PHONY: helm-diff
helm-diff: env-check helm-repo-add ## Show what a helm upgrade would change (requires helm-diff plugin)
	@helm diff upgrade $(HELM_RELEASE) $(HELM_CHART) \
		--namespace $(HELM_NAMESPACE) \
		--version "$(ISOVALENT_VERSION)" \
		--values $(HELM_VALUES) \
		--values $(HELM_VALUES_ENV)

.PHONY: uninstall
uninstall: env-check ## Uninstall Cilium (use with caution — cluster networking will be disrupted)
	@echo "WARNING: This will remove Cilium from the cluster and disrupt all pod networking."
	@echo "Press Ctrl-C within 10 seconds to abort."
	@sleep 10
	@helm uninstall $(HELM_RELEASE) -n $(HELM_NAMESPACE) --wait
