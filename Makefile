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

.PHONY: hosts
hosts: ## Make the node names resolve from this workstation (/etc/hosts + wsl.conf)
	@bash scripts/hosts-sync.sh

.PHONY: status
status: ## Show where we are (reads STATUS.md)
	@sed -n '1,40p' STATUS.md

# ---------------------------------------------------------------- on-prem

.PHONY: image
image: ## Module 01 - build the golden image with Packer (~3 min, from Ubuntu's cloud image)
	@bash scripts/build-image.sh

.PHONY: onprem-vms
onprem-vms: ## Module 01 - build the three on-prem nodes (terraform apply)
	@terraform -chdir=terraform/onprem init -input=false
	@terraform -chdir=terraform/onprem validate
	@terraform -chdir=terraform/onprem apply -auto-approve

.PHONY: onprem-vms-validate
onprem-vms-validate: ## Check the Terraform config against the real provider schema (no changes)
	@terraform -chdir=terraform/onprem init -input=false -upgrade=false >/dev/null
	@terraform -chdir=terraform/onprem validate

.PHONY: onprem-vms-plan
onprem-vms-plan: ## Show what would change without changing it
	@terraform -chdir=terraform/onprem plan

.PHONY: onprem-vms-status
onprem-vms-status: ## Show the on-prem nodes and their addresses
	@virsh -c qemu:///system list --all
	@terraform -chdir=terraform/onprem output -json nodes 2>/dev/null | jq -r 'to_entries[] | "\(.key)\t\(.value.role)\t\(.value.address)"' || true

.PHONY: onprem-console
onprem-console: ## Attach to a node's serial console (NODE=k8s-cp01) - detach with Ctrl-]
	@bash scripts/console.sh $(NODE)

.PHONY: onprem-boot-log
onprem-boot-log: ## Follow a node's recorded console log (NODE=k8s-cp01)
	@bash scripts/console.sh $(NODE) --log

.PHONY: onprem-diagnose
onprem-diagnose: ## Explain why a node is unreachable (NODE=k8s-cp01 for one)
	@bash scripts/diagnose-node.sh $(NODE)

.PHONY: onprem-vms-destroy
onprem-vms-destroy: ## Destroy the on-prem nodes (the golden image is kept)
	@terraform -chdir=terraform/onprem destroy

.PHONY: onprem-kubeadm-config
onprem-kubeadm-config: ## Module 02 - copy the kubeadm config from Git to the control plane and validate it
	@bash scripts/push-kubeadm-config.sh

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

.PHONY: reclaim
reclaim: ## Compact WSL's virtual disk after destroying VMs (ADR-0006)
	@echo "Run from PowerShell, with WSL shut down:"
	@echo "  wsl --shutdown"
	@echo "  Optimize-VHD -Path \$$env:LOCALAPPDATA\\Packages\\CanonicalGroupLimited*\\LocalState\\ext4.vhdx -Mode Full"
	@echo "(Hyper-V module required; otherwise use diskpart 'compact vdisk')"

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
