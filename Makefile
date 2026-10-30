# The method's Definition of Done gate (docs/method.md). CI runs the same target.

MARKDOWNLINT_VERSION ?= 0.24.0
PYTHON ?= python3

.PHONY: verify lint links method test

verify: lint links method test ## Everything a PR must pass

lint: ## markdownlint with .markdownlint.yaml
	npx --yes markdownlint-cli2@$(MARKDOWNLINT_VERSION) "**/*.md" "#node_modules"

links: ## every relative Markdown link resolves
	$(PYTHON) hack/check_method.py links

method: ## roadmap, planning-doc and ADR rules
	$(PYTHON) hack/check_method.py repo

test: ## tests for the method checks themselves
	$(PYTHON) -m unittest discover -s hack -p 'test_*.py'
