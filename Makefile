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
test: ## Tests for the method checks themselves.
	$(PYTHON) -m unittest discover -s hack -p 'test_*.py'

.PHONY: charts
charts: helm-lint helm-render-test crd-validate ## Lint, render tests (incl. version pin), CRD schema check.

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
