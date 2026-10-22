# platform-engineering-lab
#
# One entry point for everything. If a task is worth doing twice, it is a target here.
# Every cloud target has a matching destroy target, and `cost-check` is run at the end of
# every cloud session (ADR-0003).

SHELL := /bin/bash
.DEFAULT_GOAL := help
ENV ?= onprem

.PHONY: help
help: ## Show this help
	@echo "platform-engineering-lab"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  ENV=onprem|gcp|aws   (current: $(ENV))"

# ---------------------------------------------------------------- workstation

.PHONY: tools
tools: ## Install the workstation toolchain inside WSL (idempotent)
	@bash scripts/install-tools.sh

.PHONY: doctor
doctor: ## Check that the workstation has everything this project needs
	@bash scripts/doctor.sh

.PHONY: status
status: ## Show where we are (reads STATUS.md)
	@sed -n '1,40p' STATUS.md

# ---------------------------------------------------------------- on-prem

.PHONY: image
image: ## Module 01 - build the golden Ubuntu image (Packer runs on Windows, see ADR-0005)
	@bash scripts/build-image.sh

.PHONY: onprem-vms
onprem-vms: ## Module 01 - clone the three on-prem VMs from the golden image
	@bash scripts/onprem-vms.sh create

.PHONY: onprem-vms-status
onprem-vms-status: ## Show the on-prem VMs and their addresses
	@bash scripts/onprem-vms.sh status

.PHONY: onprem-vms-destroy
onprem-vms-destroy: ## Destroy the on-prem VMs (the image is kept)
	@bash scripts/onprem-vms.sh destroy

.PHONY: onprem-up
onprem-up: ## Module 03 - build the whole on-prem cluster from nothing
	@echo "not implemented yet - Module 03"; exit 1

.PHONY: onprem-down
onprem-down: ## Destroy the on-prem cluster (keeps the VMs)
	@echo "not implemented yet - Module 03"; exit 1

# ---------------------------------------------------------------- cloud

.PHONY: up
up: ## Create the cloud environment  (ENV=gcp|aws)
	@test "$(ENV)" != "onprem" || { echo "use onprem-up for on-prem"; exit 1; }
	@echo "not implemented yet - Module 08 (gcp) / Module 09 (aws)"; exit 1

.PHONY: down
down: ## Destroy the cloud environment  (ENV=gcp|aws) - ALWAYS run before ending a session
	@test "$(ENV)" != "onprem" || { echo "use onprem-down for on-prem"; exit 1; }
	@echo "not implemented yet - Module 08 (gcp) / Module 09 (aws)"; exit 1

.PHONY: cost-check
cost-check: ## Fail loudly if anything billable is still running in either cloud
	@bash scripts/cost-check.sh

# ---------------------------------------------------------------- platform

.PHONY: smoke
smoke: ## Run the cluster smoke test against the current kube context
	@bash scripts/smoke-test.sh

.PHONY: lint
lint: ## Lint everything that can be linted
	@set -e; \
	command -v yamllint   >/dev/null && yamllint -s . || echo "yamllint not installed, skipped"; \
	command -v terraform  >/dev/null && terraform -chdir=terraform fmt -check -recursive || true; \
	command -v ansible-lint >/dev/null && ansible-lint ansible/ || echo "ansible-lint not installed, skipped"; \
	for c in $$(find gitops -name Chart.yaml -printf '%h\n' 2>/dev/null); do helm lint $$c; done
