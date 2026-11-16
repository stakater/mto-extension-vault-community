# Vault Community Edition extension for MTO: the two charts, their checks, and
# the method's gates.
#
# `make verify` is the Definition of Done gate (docs/method.md): the docs
# checks and every chart check CI runs. A contributor who runs it, sees green
# and pushes must have actually tested the change. CI runs the same target.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := verify

LOCALBIN ?= $(CURDIR)/bin
PYTHON ?= python3
MARKDOWNLINT_VERSION ?= 0.24.0

.PHONY: help
help: ## Show the targets.
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ─── The gate ────────────────────────────────────────────────────────

.PHONY: verify
verify: lint links method test charts ## Everything a PR must pass: docs, method, and every chart check.

.PHONY: lint
lint: ## markdownlint with .markdownlint.yaml
	npx --yes markdownlint-cli2@$(MARKDOWNLINT_VERSION) "**/*.md" "#node_modules" "#bin"

.PHONY: links
links: ## Every relative Markdown link resolves.
	$(PYTHON) hack/check_method.py links

.PHONY: method
method: ## Roadmap, planning-doc and ADR rules.
	$(PYTHON) hack/check_method.py repo

.PHONY: test
test: ## Tests for the method checks, the mutation runner and the offline admission runner themselves.
	$(PYTHON) -m unittest discover -s hack -p 'test_*.py'
	go test -count=1 ./hack/admission-eval/

.PHONY: charts
charts: helm-lint helm-render-test crd-validate admission-offline ## Lint, render tests (incl. version pin), CRD schema check, admission CEL.

# ─── Chart checks ────────────────────────────────────────────────────

TENANT_CHART_DIR    ?= charts/mto-extension-vault-community
BOOTSTRAP_CHART_DIR ?= charts/mto-extension-vault-community-bootstrap

# The VCO CRDs the charts are validated against: a vendored copy of the kinds
# the charts render, from the VCO_VERSION release chart. hack/vco-crds/README.md
# records where the copy came from. There is no Namespace kind: Vault Community
# has no namespaces.
VCO_VERSION   ?= v1.0.3
VCO_HELM_REPO ?= https://redhat-cop.github.io/vault-config-operator
VCO_CRD_DIR   ?= hack/vco-crds
VCO_CRD_KINDS := secretenginemounts authenginemounts kubernetesauthengineconfigs \
                 kubernetesauthengineroles policies jwtoidcauthengineconfigs jwtoidcauthengineroles

.PHONY: helm-lint
helm-lint: helm ## Lint both charts.
	$(HELM) lint $(TENANT_CHART_DIR) --strict --set tenant=lint
	$(HELM) lint $(BOOTSTRAP_CHART_DIR) --strict

.PHONY: helm-render-test
helm-render-test: helm yq ## Render tests: emission, reserved names, mounts, RBAC, toggles, plumbing, version pin.
	HELM=$(HELM) YQ=$(YQ_BIN) ./hack/chart-render-tests.sh

.PHONY: crd-validate
crd-validate: helm yq ## Validate every rendered VCO CR against VCO's CRDs (apiserver admission pipeline).
	@test -d $(VCO_CRD_DIR) || { echo "error: VCO_CRD_DIR=$(VCO_CRD_DIR) does not exist" >&2; exit 1; }
	HELM=$(HELM) YQ=$(YQ_BIN) ./hack/crd-validate.sh $(VCO_CRD_DIR)

.PHONY: admission-offline
admission-offline: helm yq ## Run the admission policies' CEL offline (k8s.io/apiserver's plugin) against hack/lab/admission-cases.sh and the charts' own render.
	HELM=$(HELM) YQ=$(YQ_BIN) ./hack/admission-offline.sh

.PHONY: mutation-test
mutation-test: helm yq ## Weaken each guard in a copy of the repo; a check must fail for every one (hack/mutation_tests.py).
	HELM=$(HELM) YQ=$(YQ_BIN) $(PYTHON) hack/mutation_tests.py

.PHONY: vco-crds-sync
vco-crds-sync: helm ## Refresh hack/vco-crds from the VCO_VERSION release chart. Update hack/vco-crds/README.md with it.
	$(HELM) repo add vault-config-operator $(VCO_HELM_REPO) --force-update >/dev/null
	@tmp=$$(mktemp -d) && trap 'rm -rf "$$tmp"' EXIT \
		&& $(HELM) pull vault-config-operator/vault-config-operator --version $(VCO_VERSION) --untar -d "$$tmp" \
		&& for k in $(VCO_CRD_KINDS); do \
			cp "$$tmp/vault-config-operator/crds/apiextensions.k8s.io_v1_customresourcedefinition_$$k.redhatcop.redhat.io.yaml" \
				hack/vco-crds/redhatcop.redhat.io_$$k.yaml || exit 1; \
		done
	@echo "copied $(words $(VCO_CRD_KINDS)) CRDs from the vault-config-operator $(VCO_VERSION) release chart"

# ─── Release ─────────────────────────────────────────────────────────

HELM_REGISTRY ?= ghcr.io/stakater/charts
# GHCR_* is what the workflows set; GIT_* is a local override for pushing to
# your own registry.
GIT_USER  ?= $(GHCR_USERNAME)
GIT_TOKEN ?= $(GHCR_TOKEN)

.PHONY: helm-login
helm-login: helm ## Log in to the OCI chart registry.
	@if [ -z "$(GIT_USER)" ] || [ -z "$(GIT_TOKEN)" ]; then \
		echo "GIT_USER/GIT_TOKEN (or GHCR_USERNAME/GHCR_TOKEN) must be set"; exit 1; \
	fi
	@echo "$(GIT_TOKEN)" | $(HELM) registry login $(firstword $(subst /, ,$(HELM_REGISTRY))) -u "$(GIT_USER)" --password-stdin

.PHONY: helm-release
# Tenant chart FIRST: the bootstrap pins it by exact version, so publishing the
# bootstrap first leaves a window where its child Templates name a chart tag that
# 404s and every tenant renders nothing. A version that is already published is
# skipped (hack/release-chart.sh says why).
helm-release: helm helm-login ## Release both charts to OCI; skips versions already published.
	$(HELM) lint $(TENANT_CHART_DIR) --strict --set tenant=lint
	$(HELM) lint $(BOOTSTRAP_CHART_DIR) --strict
	HELM=$(HELM) ./hack/release-chart.sh $(TENANT_CHART_DIR) $(HELM_REGISTRY)
	HELM=$(HELM) ./hack/release-chart.sh $(BOOTSTRAP_CHART_DIR) $(HELM_REGISTRY)

BASE ?= origin/main

.PHONY: version-bump-check
version-bump-check: ## PR check: a chart that changed against BASE must bump its version.
	./hack/version-bump-check.sh $(BASE) $(TENANT_CHART_DIR) $(BOOTSTRAP_CHART_DIR)

# ─── Tools ───────────────────────────────────────────────────────────

# A system binary wins over the pinned download, so *_VERSION is what we fetch
# and *_MIN is the floor enforced against whatever is actually used. curl -f
# matters: without it curl writes the HTTP error body to the destination and
# exits 0, so an error page becomes the cached tool.
HELM         ?= $(shell command -v helm || echo $(LOCALBIN)/helm)
HELM_VERSION ?= v3.19.0
HELM_MIN     ?= 3.14
YQ_BIN       ?= $(shell command -v yq || echo $(LOCALBIN)/yq)
YQ_VERSION   ?= v4.44.3
# 4.40 is where the render harness runs clean; older builds get sort_keys wrong
# and fail as a golden diff with no hint that yq is the cause.
YQ_MIN       ?= 4.40

OS_LOWER = $$(uname | tr '[:upper:]' '[:lower:]')
ARCH_GO  = $$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

.PHONY: helm
helm: ## Ensure a helm binary of at least $(HELM_MIN) is available.
	@if [ ! -x "$(HELM)" ]; then \
		echo "Downloading helm $(HELM_VERSION)"; mkdir -p $(LOCALBIN); tmp=$$(mktemp -d); \
		curl -fsSL -o $$tmp/helm.tar.gz "https://get.helm.sh/helm-$(HELM_VERSION)-$(OS_LOWER)-$(ARCH_GO).tar.gz"; \
		tar -zxf $$tmp/helm.tar.gz -C $$tmp; mv $$tmp/$(OS_LOWER)-$(ARCH_GO)/helm $(LOCALBIN)/helm; \
		chmod +x $(LOCALBIN)/helm; rm -rf $$tmp; \
	fi
	@have=$$($(HELM) version --template '{{.Version}}' 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1); \
	if [ -z "$$have" ]; then echo "$(HELM) is not a working helm binary — delete it and re-run"; exit 1; fi; \
	if [ "$$(printf '%s\n%s\n' "$(HELM_MIN)" "$$have" | sort -V | head -1)" != "$(HELM_MIN)" ]; then \
		echo "helm $$have is older than the required $(HELM_MIN) ($(HELM))"; exit 1; \
	fi

.PHONY: yq
yq: ## Ensure a yq binary of at least $(YQ_MIN) is available.
	@if [ ! -x "$(YQ_BIN)" ]; then \
		echo "Downloading yq $(YQ_VERSION)"; mkdir -p $(LOCALBIN); tmp=$$(mktemp); \
		curl -fsSL -o $$tmp "https://github.com/mikefarah/yq/releases/download/$(YQ_VERSION)/yq_$(OS_LOWER)_$(ARCH_GO)"; \
		chmod +x $$tmp; $$tmp --version >/dev/null; mv $$tmp $(LOCALBIN)/yq; \
	fi
	@have=$$($(YQ_BIN) --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1); \
	if [ -z "$$have" ]; then echo "$(YQ_BIN) is not a working yq binary — delete it and re-run"; exit 1; fi; \
	if [ "$$(printf '%s\n%s\n' "$(YQ_MIN)" "$$have" | sort -V | head -1)" != "$(YQ_MIN)" ]; then \
		echo "yq $$have is older than the required $(YQ_MIN) ($(YQ_BIN))"; exit 1; \
	fi

# ─── Lab ─────────────────────────────────────────────────────────────
#
# One kind cluster with everything the extension needs:
#   cert-manager                 t-op-v2's and VCO's webhook certificates
#   MTO Tenant CRD               the parent Template's input (MTO itself is not installed)
#   template-operator-v2         the renderer
#   External Secrets, Reloader   delivery and rotation
#   Vault Community (dev mode)   the only edition this extension supports
#   vault-config-operator (VCO)  the VCO_VERSION release chart
#
# `make lab-up` builds all of it; every target is idempotent, so a re-run after
# a failure reuses what is already up.

CLUSTER_NAME ?= vault-ce-lab
KIND_CONFIG  ?= hack/lab/kind-config.yaml
# Every target names its context: never the ambient current-context.
CONTEXT ?= kind-$(CLUSTER_NAME)
# The lab targets delete pods, install dev-mode Vault and write root-token
# state. CONTEXT is read from the environment too, so an exported CONTEXT=prod
# would aim them at that cluster: they refuse any context but a kind one.
LAB_GOALS := $(filter lab-% e2e-% admission-test,$(MAKECMDGOALS))
ifneq ($(LAB_GOALS),)
ifeq ($(filter kind-%,$(CONTEXT)),)
$(error CONTEXT=$(CONTEXT) is not a kind cluster's context (kind-*): the lab targets ($(LAB_GOALS)) only run against the lab)
endif
endif
KUBECTL ?= kubectl
KIND    ?= kind
CONTAINER_TOOL ?= docker
KC = $(KUBECTL) --context $(CONTEXT)

CERT_MANAGER_VERSION ?= v1.20.0
CERT_MANAGER_URL     ?= https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VERSION)/cert-manager.yaml

# template-operator-v2: built from a local checkout's TOV2_REF (TOV2_FROM=src,
# the default when TOV2_SRC exists), or the public chart (TOV2_FROM=chart, the
# default in CI). The source build never switches the checkout's branch: it
# archives TOV2_REF into a scratch directory.
TOV2_SRC  ?= ../template-operator-v2
TOV2_REF  ?= origin/main
TOV2_FROM ?= $(if $(wildcard $(TOV2_SRC)/go.mod),src,chart)
TOV2_IMG  ?= template-operator-v2:lab
# The chart's release name MUST be template-operator-v2: its Certificate
# hardcodes issuerRef.name=template-operator-v2-selfsigned-issuer.
TOV2_RELEASE       := template-operator-v2
TOV2_CHART         ?= oci://ghcr.io/stakater/public/charts/template-operator-v2
TOV2_CHART_VERSION ?= 0.0.7
TOV2_DEPLOYMENT    ?= template-operator-v2-controller-manager
ifeq ($(TOV2_FROM),src)
TOV2_NS ?= template-operator-v2-system
TOV2_SA ?= template-operator-v2-controller-manager
else
TOV2_NS ?= stakater-template-operator
TOV2_SA ?= $(TOV2_RELEASE)
endif

ESO_CHART_VERSION      ?= 2.11.0
RELOADER_CHART_VERSION ?= 2.2.17

VAULT_NS            := vault
VAULT_CHART_VERSION ?= 0.34.1
VAULT_VERSION       ?= 2.1.1

VCO_NS        ?= vault-config-operator
VCO_RELEASE   ?= vault-config-operator
# Drift detection is off by default in VCO. The lab turns it on with a short
# period, so out-of-band edits are reverted quickly — and so the e2e suite can
# watch objects across several drift reconciles in well under a minute.
VCO_SYNC_PERIOD_SECONDS ?= 30

# The Kubernetes namespace that holds every VCO CR, and the ServiceAccount the
# CRs log in to Vault with (spec.authentication.serviceAccount).
CONFIG_NS ?= vault-config
CONFIG_SA ?= vco-admin
VERIFY_LOGIN ?= 1
CHART_REPO_URL ?= http://chart-repo.chart-repo.svc.cluster.local

LAB_VCO_KINDS := secretenginemounts.redhatcop.redhat.io,authenginemounts.redhatcop.redhat.io,kubernetesauthengineconfigs.redhatcop.redhat.io,kubernetesauthengineroles.redhatcop.redhat.io,policies.redhatcop.redhat.io,jwtoidcauthengineconfigs.redhatcop.redhat.io,jwtoidcauthengineroles.redhatcop.redhat.io

define wait-crd
	@ok=""; for i in 1 2 3; do \
		$(KC) wait crd $(1) --for=condition=Established --timeout=60s && { ok=1; break; }; \
		echo "  CRDs not established yet, retrying ($$i/3)"; sleep 5; \
	done; \
	if [ -z "$$ok" ]; then echo "error: CRDs $(1) never became Established" >&2; exit 1; fi
endef

.PHONY: lab-up
lab-up: lab-cluster lab-cert-manager lab-tenant-crd lab-tov2 lab-eso lab-reloader lab-vault lab-keycloak lab-dex lab-vco lab-chart-repo lab-bootstrap lab-vault-bootstrap ## Build the whole lab.

.PHONY: lab-down
lab-down: ## Delete the lab cluster.
	$(KIND) delete cluster --name $(CLUSTER_NAME)

.PHONY: lab-cluster
lab-cluster: ## Create the kind cluster (idempotent).
	@# Listed on its own line: piped into grep -q, a failed `kind get` read as
	@# "no cluster", and under pipefail grep's early exit could fail kind.
	@clusters=$$($(KIND) get clusters) || exit $$?; \
	if grep -qx '$(CLUSTER_NAME)' <<<"$$clusters"; then \
		echo "kind cluster $(CLUSTER_NAME) already exists"; \
	else \
		$(KIND) create cluster --name $(CLUSTER_NAME) --config $(KIND_CONFIG); \
	fi

.PHONY: lab-cert-manager
lab-cert-manager: ## Install cert-manager and wait until its webhook answers.
	$(KC) apply -f $(CERT_MANAGER_URL)
	$(KC) wait deployment.apps/cert-manager-webhook --for=condition=Available -n cert-manager --timeout=300s
	$(call wait-crd,certificates.cert-manager.io issuers.cert-manager.io)
	@# Available=True does not mean the webhook answers. Issuing a throwaway
	@# Issuer is the check; on exhaustion the target fails with the last error.
	@probe='{"apiVersion":"cert-manager.io/v1","kind":"Issuer","metadata":{"name":"cm-readiness-probe","namespace":"cert-manager"},"spec":{"selfSigned":{}}}'; \
	ok=""; for i in $$(seq 1 30); do \
		echo "$$probe" | $(KC) apply -f - >/dev/null 2>&1 && \
		$(KC) delete issuer cm-readiness-probe -n cert-manager >/dev/null 2>&1 && { ok=1; break; }; \
		echo "  cert-manager webhook not ready yet ($$i/30)"; sleep 4; \
	done; \
	if [ -z "$$ok" ]; then \
		echo "error: cert-manager webhook never became ready; the last attempt said:" >&2; \
		echo "$$probe" | $(KC) apply -f - 1>&2 || true; \
		exit 1; \
	fi

.PHONY: lab-tenant-crd
lab-tenant-crd: ## Install MTO's Tenant CRD (only the CRD, not MTO).
	$(KC) apply -f hack/lab/crds/tenantoperator.stakater.com_tenants.yaml
	$(call wait-crd,tenants.tenantoperator.stakater.com)

.PHONY: lab-tov2
lab-tov2: helm ## Install template-operator-v2: TOV2_FROM=src builds TOV2_REF of TOV2_SRC, TOV2_FROM=chart the public chart.
ifeq ($(TOV2_FROM),src)
	@test -f $(TOV2_SRC)/go.mod || { echo "error: TOV2_SRC=$(TOV2_SRC) is not a template-operator-v2 checkout" >&2; exit 1; }
	git -C $(TOV2_SRC) fetch -q origin
	@tmp=$$(mktemp -d) && trap 'rm -rf "$$tmp"' EXIT \
		&& git -C $(TOV2_SRC) archive $(TOV2_REF) | tar -x -C "$$tmp" \
		&& echo "building template-operator-v2 $$(git -C $(TOV2_SRC) rev-parse --short $(TOV2_REF)) as $(TOV2_IMG)" \
		&& $(CONTAINER_TOOL) build -q -t $(TOV2_IMG) "$$tmp" >/dev/null \
		&& $(CONTAINER_TOOL) save $(TOV2_IMG) | $(CONTAINER_TOOL) exec -i $(CLUSTER_NAME)-control-plane ctr --namespace=k8s.io images import --all-platforms - >/dev/null \
		&& (cd "$$tmp/config/manager" && kustomize edit set image controller=$(TOV2_IMG)) \
		&& kustomize build "$$tmp/config/default" | $(KC) apply --server-side --force-conflicts -f - >/dev/null
	@# Same tag, new image: restart so the pod picks up the build just loaded.
	$(KC) -n $(TOV2_NS) rollout restart deploy/$(TOV2_DEPLOYMENT)
else
	$(KC) create namespace $(TOV2_NS) --dry-run=client -o yaml | $(KC) apply -f -
	$(HELM) upgrade --install $(TOV2_RELEASE) $(TOV2_CHART) --version $(TOV2_CHART_VERSION) \
		--kube-context $(CONTEXT) -n $(TOV2_NS) --reset-values
endif
	@# Before the rollout wait: an unscoped sync-enforcement webhook deadlocks
	@# the cluster. The script explains why; on a scoped install it only
	@# confirms the scoping.
	KUBECTL=$(KUBECTL) E2E_CONTEXT=$(CONTEXT) \
		WEBHOOK_NAME=$(TOV2_RELEASE)-template-operator-v2-sync-enforcement \
		./hack/lab/scope-tov2-webhook.sh
	$(KC) -n $(TOV2_NS) rollout status deploy/$(TOV2_DEPLOYMENT) --timeout=300s

.PHONY: lab-eso
lab-eso: helm ## Install External Secrets Operator (the .eso slice's SecretStore/ExternalSecret).
	$(HELM) repo add external-secrets https://charts.external-secrets.io --force-update >/dev/null
	$(HELM) upgrade --install external-secrets external-secrets/external-secrets \
		--version $(ESO_CHART_VERSION) \
		--kube-context $(CONTEXT) -n external-secrets --create-namespace --reset-values \
		--wait --timeout 5m
	$(call wait-crd,secretstores.external-secrets.io externalsecrets.external-secrets.io)

.PHONY: lab-reloader
lab-reloader: helm ## Install Stakater Reloader: restarts a Deployment when a Secret or ConfigMap it uses changes.
	$(HELM) repo add stakater https://stakater.github.io/stakater-charts --force-update >/dev/null
	$(HELM) upgrade --install reloader stakater/reloader \
		--version $(RELOADER_CHART_VERSION) \
		--kube-context $(CONTEXT) -n reloader --create-namespace --reset-values \
		--wait --timeout 5m

.PHONY: lab-vault
lab-vault: helm ## Install Vault Community Edition $(VAULT_VERSION) in dev mode.
	$(KC) create namespace $(VAULT_NS) --dry-run=client -o yaml | $(KC) apply -f -
	$(HELM) repo add hashicorp https://helm.releases.hashicorp.com --force-update >/dev/null
	$(HELM) upgrade --install vault hashicorp/vault --version $(VAULT_CHART_VERSION) \
		--kube-context $(CONTEXT) -n $(VAULT_NS) -f hack/lab/vault-values.yaml \
		--set server.image.repository=hashicorp/vault \
		--set server.image.tag=$(VAULT_VERSION)
	@# The chart's StatefulSet uses OnDelete, so an upgrade only reaches the pod
	@# when the pod is deleted. Dev mode is in-memory anyway.
	$(KC) -n $(VAULT_NS) delete pod vault-0 --ignore-not-found --wait=true
	@# kubectl wait fails at once on a pod that does not exist yet, and the
	@# StatefulSet takes a moment to create it (on a first install, too).
	@for i in $$(seq 1 60); do $(KC) -n $(VAULT_NS) get pod vault-0 >/dev/null 2>&1 && break; sleep 2; done
	$(KC) -n $(VAULT_NS) wait --for=condition=Ready pod/vault-0 --timeout=300s

.PHONY: lab-vault-bootstrap
lab-vault-bootstrap: ## Give VCO a kubernetes-auth login in Vault (the lab policy), and prove it.
	CONTEXT=$(CONTEXT) KUBECTL=$(KUBECTL) VAULT_NS=$(VAULT_NS) \
		CONFIG_NS=$(CONFIG_NS) SA=$(CONFIG_SA) ROLE=$(CONFIG_SA) VERIFY_LOGIN=$(VERIFY_LOGIN) \
		./hack/lab/vault-bootstrap.sh

# The VCO settings the lab uses.
#   enableMonitoring=false: the chart otherwise renders a ServiceMonitor, and
#   kind has no Prometheus CRDs (upstream issue #221).
#   CACHE_VAULT_TOKEN=true: VCO reuses and renews one Vault token. Without it
#   VCO logs in again on every reconcile, and with drift detection every
#   SYNC_PERIOD_SECONDS that piles up thousands of live tokens in Vault.
VCO_HELM_SETTINGS = --kube-context $(CONTEXT) -n $(VCO_NS) --create-namespace --skip-crds \
	--set enableCertManager=true \
	--set enableMonitoring=false \
	--set 'env[0].name=VAULT_ADDR' --set 'env[0].value=http://vault.$(VAULT_NS).svc:8200' \
	--set 'env[1].name=ENABLE_DRIFT_DETECTION' --set-string 'env[1].value=true' \
	--set 'env[2].name=SYNC_PERIOD_SECONDS' --set-string 'env[2].value=$(VCO_SYNC_PERIOD_SECONDS)' \
	--set 'env[3].name=CACHE_VAULT_TOKEN' --set-string 'env[3].value=true'

.PHONY: lab-vco
lab-vco: helm ## Install VCO $(VCO_VERSION) from its release chart, pointed at the lab Vault.
	$(HELM) repo add vault-config-operator $(VCO_HELM_REPO) --force-update >/dev/null
	@# helm installs crds/ only on the first install and never upgrades them, so
	@# the release's CRDs are applied explicitly.
	@tmp=$$(mktemp -d) && trap 'rm -rf "$$tmp"' EXIT \
		&& $(HELM) pull vault-config-operator/vault-config-operator --version $(VCO_VERSION) --untar -d "$$tmp" \
		&& $(KC) apply --server-side --force-conflicts -f "$$tmp/vault-config-operator/crds/" >/dev/null \
		&& echo "applied the CRDs of vault-config-operator $(VCO_VERSION)"
	$(HELM) upgrade --install $(VCO_RELEASE) vault-config-operator/vault-config-operator --version $(VCO_VERSION) \
		$(VCO_HELM_SETTINGS)
	$(KC) -n $(VCO_NS) rollout status deploy/$(VCO_RELEASE) --timeout=300s

.PHONY: lab-chart-repo
lab-chart-repo: helm ## Serve THIS checkout's tenant chart from an in-cluster HTTP repo for t-op-v2 to pull.
	$(KC) apply -f hack/lab/chart-repo.yaml
	KUBECTL=$(KUBECTL) HELM=$(HELM) E2E_CONTEXT=$(CONTEXT) CHART_DIR=$(TENANT_CHART_DIR) \
		./hack/lab/chart-repo-publish.sh

.PHONY: lab-bootstrap
lab-bootstrap: helm ## Install the bootstrap chart from this checkout, pulling the tenant chart from the lab repo.
	$(HELM) upgrade --install mto-extension-vault-community-bootstrap $(BOOTSTRAP_CHART_DIR) \
		--kube-context $(CONTEXT) -n $(CONFIG_NS) --create-namespace \
		--set configNamespace=$(CONFIG_NS) \
		--set vco.serviceAccount=$(CONFIG_SA) --set vco.role=$(CONFIG_SA) \
		--set templateOperator.serviceAccountName=$(TOV2_SA) \
		--set templateOperator.namespace=$(TOV2_NS) \
		--set tenantChart.registry=$(CHART_REPO_URL) \
		--set parent.vaultServer=http://vault.$(VAULT_NS).svc:8200 \
		--set parent.eso=enabled \
		--set parent.sso.enabled=true --set parent.sso.issuerUrl=$(DEX_ISSUER) \
		--set 'parent.sso.allowedRedirectUris[0]=$(CLI_CALLBACK)' \
		--set 'parent.sso.allowedRedirectUris[1]=$(UI_CALLBACK)'
	@# Vault's side of the Dex "vault" client: the same secret, in CONFIG_NS.
	@$(KC) -n $(DEX_NS) get secret dex-vault-client -o json \
		| jq '{apiVersion: "v1", kind: "Secret", type: "Opaque", metadata: {name: "vault-oidc-client-secret", namespace: "$(CONFIG_NS)"}, data: {"client-secret": .data["client-secret"]}}' \
		| $(KC) apply -f -

.PHONY: lab-uninstall
lab-uninstall: helm ## Uninstall the bootstrap chart in the documented order (charts/README.md → Uninstall).
	@# The full name: on OpenShift the short name is OpenShift's own kind, and
	@# --ignore-not-found would then hide that nothing was deleted.
	$(KC) -n $(CONFIG_NS) delete templateinstances.templates.v2.stakater.com mto-extension-vault-community-parent --ignore-not-found --wait --timeout=5m
	@# The RBAC and the VCO login ServiceAccount must outlive every CR they
	@# tear down, so the release goes only once no VCO CR is left.
	@left=""; for i in $$(seq 1 60); do \
		if ! out=$$($(KC) -n $(CONFIG_NS) get $(LAB_VCO_KINDS) -o name 2>/tmp/lab-uninstall.err); then \
			echo "error: cannot list VCO CRs — not uninstalling the release:" >&2; cat /tmp/lab-uninstall.err >&2; exit 1; \
		fi; \
		left=$$(printf '%s' "$$out" | grep -c . || true); \
		[ "$$left" = 0 ] && break; sleep 5; \
	done; \
	if [ "$$left" != 0 ]; then echo "error: $$left VCO CRs still in $(CONFIG_NS) after 5m — not uninstalling the release:" >&2; \
		$(KC) -n $(CONFIG_NS) get $(LAB_VCO_KINDS) >&2; exit 1; fi
	$(HELM) uninstall mto-extension-vault-community-bootstrap --kube-context $(CONTEXT) -n $(CONFIG_NS) --wait

.PHONY: lab-render
lab-render: ## Apply the sample Tenants, their labelled namespaces and annotated ServiceAccounts.
	$(KC) apply -f hack/lab/sample-tenants.yaml

# SSO, as in production: person -> Vault -> Dex -> Keycloak. The namespaces and
# URLs are fixed: hack/lab/keycloak*.yaml name them too.
KEYCLOAK_NS  := keycloak
DEX_NS       := dex
KEYCLOAK_URL := http://keycloak.$(KEYCLOAK_NS).svc.cluster.local:8080
DEX_ISSUER   := http://dex.$(DEX_NS).svc.cluster.local:5556
# The lab Keycloak's test users: hack/lab/keycloak-setup-job.yaml puts each in a group.
KEYCLOAK_TEST_USERS := alice bob carol dave erin
DEX_CHART_VERSION ?= 0.25.2
# Each tenant's SSO mount has its own UI callback, and Dex allows no wildcard
# in a redirect URI, so its "vault" client lists one per tenant: these, plus
# the CLI's loopback callback that every mount shares.
DEX_TENANTS ?= e2e-alpha e2e-beta team-a team-b
CLI_CALLBACK := http://localhost:8250/oidc/callback
UI_CALLBACK  := http://vault.$(VAULT_NS).svc:8200/ui/vault/auth/{tenant}/oidc/sso/oidc/callback

.PHONY: lab-keycloak
lab-keycloak: ## Install Keycloak: realm mto, client dex, a group per tenant and role, five test users.
	$(KC) create namespace $(KEYCLOAK_NS) --dry-run=client -o yaml | $(KC) apply -f -
	@# Random secrets, made only when missing: a re-run must not change a password
	@# that Keycloak, Dex or a running test already holds. Never printed.
	@$(KC) -n $(KEYCLOAK_NS) get secret keycloak-admin >/dev/null 2>&1 \
		|| $(KC) -n $(KEYCLOAK_NS) create secret generic keycloak-admin \
			--from-literal=username=admin --from-literal=password="$$(openssl rand -hex 16)"
	@$(KC) -n $(KEYCLOAK_NS) get secret keycloak-dex-client >/dev/null 2>&1 \
		|| $(KC) -n $(KEYCLOAK_NS) create secret generic keycloak-dex-client \
			--from-literal=client-secret="$$(openssl rand -hex 24)"
	@$(KC) -n $(KEYCLOAK_NS) get secret keycloak-test-users >/dev/null 2>&1 \
		|| $(KC) -n $(KEYCLOAK_NS) create secret generic keycloak-test-users >/dev/null
	@for u in $(KEYCLOAK_TEST_USERS); do \
		have=$$($(KC) -n $(KEYCLOAK_NS) get secret keycloak-test-users -o jsonpath="{.data.$$u}") || exit 1; \
		[ -n "$$have" ] || $(KC) -n $(KEYCLOAK_NS) patch secret keycloak-test-users --type merge \
			-p "{\"stringData\":{\"$$u\":\"$$(openssl rand -hex 8)\"}}" >/dev/null || exit 1; \
	done
	$(KC) apply -f hack/lab/keycloak.yaml
	$(KC) -n $(KEYCLOAK_NS) rollout status deploy/keycloak --timeout=300s
	@# Dev mode keeps the realm in memory, so the setup runs on every call.
	$(KC) -n $(KEYCLOAK_NS) delete job keycloak-setup --ignore-not-found --wait=true
	$(KC) apply -f hack/lab/keycloak-setup-job.yaml
	$(KC) -n $(KEYCLOAK_NS) wait --for=condition=Complete job/keycloak-setup --timeout=300s

.PHONY: lab-dex
lab-dex: helm ## Install Dex, connected to the lab Keycloak; its config is built from Secrets, never printed.
	$(KC) create namespace $(DEX_NS) --dry-run=client -o yaml | $(KC) apply -f -
	@$(KC) -n $(DEX_NS) get secret dex-vault-client >/dev/null 2>&1 \
		|| $(KC) -n $(DEX_NS) create secret generic dex-vault-client \
			--from-literal=client-secret="$$(openssl rand -hex 24)"
	@# The config as JSON (a subset of YAML, which Dex reads), with both client
	@# secrets read from their Secrets inside jq: none passes through the shell.
	@# The program is a file: GNU make keeps a backslash-newline inside quotes
	@# (DX.4; hack/test_makefile_recipes.py).
	@kc_secret=$$($(KC) -n $(KEYCLOAK_NS) get secret keycloak-dex-client -o json) || exit 1; \
	vault_secret=$$($(KC) -n $(DEX_NS) get secret dex-vault-client -o json) || exit 1; \
	jq -n --argjson kc "$$kc_secret" --argjson vc "$$vault_secret" \
		--arg issuer "$(DEX_ISSUER)" --arg kcurl "$(KEYCLOAK_URL)" --arg cli "$(CLI_CALLBACK)" \
		--arg ui "$(UI_CALLBACK)" --arg tenants "$(DEX_TENANTS)" --arg ns "$(DEX_NS)" \
		-f hack/lab/dex-config.jq \
		| $(KC) apply -f - >/dev/null
	$(HELM) repo add dex https://charts.dexidp.io --force-update >/dev/null
	$(HELM) upgrade --install dex dex/dex --version $(DEX_CHART_VERSION) \
		--kube-context $(CONTEXT) -n $(DEX_NS) -f hack/lab/dex-values.yaml --wait --timeout 5m
	@# A new config reaches Dex only on a restart.
	$(KC) -n $(DEX_NS) rollout restart deploy/dex
	$(KC) -n $(DEX_NS) rollout status deploy/dex --timeout=300s
	@# Vault fetches the issuer's discovery document from inside its pod: prove
	@# it works there. Right after the restart a try can hit the old pod, so the
	@# script tries again, each try with a short timeout (DX.3).
	@KUBECTL=$(KUBECTL) CONTEXT=$(CONTEXT) VAULT_NS=$(VAULT_NS) DEX_ISSUER=$(DEX_ISSUER) \
		./hack/lab/dex-reachable.sh

# ─── E2E ─────────────────────────────────────────────────────────────

# The suite (tests/e2e) installs and uninstalls the bootstrap chart itself, and
# brings its own tenants, so it runs against the plain lab. It needs Vault
# COMMUNITY Edition — it refuses Enterprise, where a tenant is a namespace.
E2E_WAIT_TIMEOUT ?= 4m
# Set by e2e-kind: a failed run keeps its state for e2e-diagnostics.
E2E_KEEP_ON_FAILURE ?=
# go test's own limit. Keep it below the CI job's timeout-minutes (e2e.yaml)
# minus the lab build: a job killed by CI runs no diagnostics.
E2E_GO_TIMEOUT ?= 45m

.PHONY: e2e-up
e2e-up: lab-cluster lab-cert-manager lab-tenant-crd lab-tov2 lab-eso lab-reloader lab-vault lab-keycloak lab-dex lab-vco lab-chart-repo ## The lab without the bootstrap chart: what the e2e suite starts from.
	$(MAKE) lab-vault-bootstrap VERIFY_LOGIN=0

.PHONY: e2e-test
e2e-test: helm ## Run tests/e2e against the lab. E2E_KEEP=1 leaves the install in place.
	E2E=1 KUBE_CONTEXT=$(CONTEXT) HELM=$(HELM) KUBECTL=$(KUBECTL) \
		E2E_CHART_REPO_URL=$(CHART_REPO_URL) \
		E2E_TOV2_SA=system:serviceaccount:$(TOV2_NS):$(TOV2_SA) \
		E2E_CONFIG_NAMESPACE=$(CONFIG_NS) E2E_VAULT_NAMESPACE=$(VAULT_NS) \
		E2E_VAULT_SERVER=http://vault.$(VAULT_NS).svc:8200 \
		E2E_WAIT_TIMEOUT=$(E2E_WAIT_TIMEOUT) E2E_VCO_SYNC_PERIOD=$(VCO_SYNC_PERIOD_SECONDS)s \
		E2E_KEEP_ON_FAILURE=$(E2E_KEEP_ON_FAILURE) \
		E2E_VCO_NAMESPACE=$(VCO_NS) E2E_VCO_DEPLOYMENT=$(VCO_RELEASE) \
		E2E_DEX_ISSUER=$(DEX_ISSUER) E2E_KEYCLOAK_URL=$(KEYCLOAK_URL) \
		E2E_DEX_NAMESPACE=$(DEX_NS) E2E_KEYCLOAK_NAMESPACE=$(KEYCLOAK_NS) \
		E2E_UI_CALLBACK='$(UI_CALLBACK)' \
		go test ./tests/e2e/ -count=1 -v -timeout $(E2E_GO_TIMEOUT)

.PHONY: e2e-kind
e2e-kind: ## Build the lab and run the suite. Dumps ./e2e-logs on failure.
	$(MAKE) e2e-up && $(MAKE) e2e-test E2E_KEEP_ON_FAILURE=1 || { $(MAKE) e2e-diagnostics; exit 1; }

.PHONY: e2e-diagnostics
e2e-diagnostics: ## Dump cluster state and controller logs into ./e2e-logs.
	@mkdir -p e2e-logs
	-$(KC) get templateinstances.templates.v2.stakater.com,templates.templates.v2.stakater.com -A -o wide > e2e-logs/templates.txt 2>&1
	-$(KC) -n $(CONFIG_NS) get $(LAB_VCO_KINDS) -o yaml > e2e-logs/vco-crs.yaml 2>&1
	-$(KC) get externalsecrets,secretstores -A -o yaml > e2e-logs/eso.yaml 2>&1
	-$(KC) get pods -A -o wide > e2e-logs/pods.txt 2>&1
	-$(KC) -n $(TOV2_NS) logs deploy/$(TOV2_DEPLOYMENT) --tail=5000 > e2e-logs/tov2.log 2>&1
	-$(KC) -n $(VCO_NS) logs deploy/$(VCO_RELEASE) --tail=5000 > e2e-logs/vco.log 2>&1
	-$(KC) -n external-secrets logs deploy/external-secrets --tail=2000 > e2e-logs/eso.log 2>&1
	-$(KC) -n reloader logs deploy/reloader-reloader --tail=2000 > e2e-logs/reloader.log 2>&1
	-$(KC) -n $(VAULT_NS) logs vault-0 --tail=2000 > e2e-logs/vault.log 2>&1
	-$(KC) -n $(DEX_NS) logs deploy/dex --tail=2000 > e2e-logs/dex.log 2>&1
	-$(KC) -n $(KEYCLOAK_NS) logs deploy/keycloak --tail=2000 > e2e-logs/keycloak.log 2>&1
	@echo "diagnostics in ./e2e-logs"

.PHONY: admission-test
admission-test: ## Run the admission-policy cases against the lab (dry runs; an update case's old object is real; needs lab-bootstrap).
	CONTEXT=$(CONTEXT) KUBECTL=$(KUBECTL) CONFIG_NS=$(CONFIG_NS) ISSUER=$(DEX_ISSUER) \
		TOV_USER=system:serviceaccount:$(TOV2_NS):$(TOV2_SA) ./hack/lab/admission-cases.sh

# ─── Contract parity ─────────────────────────────────────────────────

# The Enterprise tenant chart whose workload contract this chart keeps
# (ADR-0001). contract-sync archives ENTERPRISE_REF into a scratch directory:
# it never switches the checkout's branch.
ENTERPRISE_SRC ?= ../mto-extension-vault-enterprise
ENTERPRISE_REF ?= origin/main

.PHONY: contract-sync
contract-sync: helm yq ## Regenerate hack/enterprise-contract.txt from ENTERPRISE_REF of ENTERPRISE_SRC.
	@test -d $(ENTERPRISE_SRC)/charts/mto-extension-vault-enterprise || { echo "error: ENTERPRISE_SRC=$(ENTERPRISE_SRC) is not an Enterprise extension checkout" >&2; exit 1; }
	git -C $(ENTERPRISE_SRC) fetch -q origin
	@tmp=$$(mktemp -d) && trap 'rm -rf "$$tmp"' EXIT \
		&& git -C $(ENTERPRISE_SRC) archive $(ENTERPRISE_REF) charts/mto-extension-vault-enterprise | tar -x -C "$$tmp" \
		&& sha=$$(git -C $(ENTERPRISE_SRC) rev-parse --short $(ENTERPRISE_REF)) \
		&& { echo "# The workload contract of the Enterprise tenant chart, from hack/contract.sh."; \
		     echo "# Source: stakater/mto-extension-vault-enterprise $(ENTERPRISE_REF) at $$sha."; \
		     echo "# Regenerate with: make contract-sync ENTERPRISE_SRC=<checkout> ENTERPRISE_REF=<ref>"; \
		     HELM=$(HELM) YQ=$(YQ_BIN) ./hack/contract.sh "$$tmp/charts/mto-extension-vault-enterprise"; } > hack/enterprise-contract.txt
	@echo "regenerated hack/enterprise-contract.txt — review the diff, and the delta in hack/contract-delta.txt"
