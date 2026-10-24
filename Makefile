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

# Ansible reads its config relative to the CURRENT DIRECTORY, not to ansible.cfg's own
# location, so every target below runs from the repository root.
ANSIBLE_ENV  := ANSIBLE_CONFIG=ansible/ansible.cfg
PLAYBOOK     := $(ANSIBLE_ENV) ansible-playbook

.PHONY: onprem-ping
onprem-ping: ## Module 03 - can Ansible reach all three nodes?
	@$(ANSIBLE_ENV) ansible all -m ping

.PHONY: onprem-inventory
onprem-inventory: ## Module 03 - show the inventory derived from nodes.json
	@$(ANSIBLE_ENV) ansible-inventory --graph --vars

.PHONY: onprem-preflight
onprem-preflight: ## Module 03 - assert the golden image did its job (changes nothing)
	@$(PLAYBOOK) ansible/playbooks/cluster.yml --tags preflight

.PHONY: onprem-check
onprem-check: ## Module 03 - dry run the whole cluster playbook (--check --diff)
	@$(PLAYBOOK) ansible/playbooks/cluster.yml --check --diff

.PHONY: onprem-up
onprem-up: ## Module 03 - build the whole on-prem cluster from nothing
	@$(PLAYBOOK) ansible/playbooks/cluster.yml

.PHONY: onprem-config
onprem-config: ## Module 03 - re-render the kubeadm config only
	@$(PLAYBOOK) ansible/playbooks/cluster.yml --tags config

.PHONY: onprem-argocd
onprem-argocd: ## Module 04 - install/repair Argo CD and re-apply the GitOps seam
	@$(PLAYBOOK) ansible/playbooks/cluster.yml --tags argocd

.PHONY: onprem-down
onprem-down: ## Destroy the on-prem cluster (keeps the VMs)
	@$(PLAYBOOK) ansible/playbooks/reset.yml

# ---------------------------------------------------------------- gitops

.PHONY: argocd-password
argocd-password: ## Show the Argo CD admin password (from the Secret, never from Git)
	@kubectl -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: argocd-ui
argocd-ui: ## Port-forward the Argo CD UI to http://localhost:8080 (Ctrl-C to stop)
	@echo "user: admin   password: $$(make -s argocd-password)"
	@echo "open http://localhost:8080"
	@kubectl -n argocd port-forward svc/argocd-server 8080:80

.PHONY: gitops-status
gitops-status: ## What Argo CD thinks the cluster should look like, and whether it agrees
	@kubectl -n argocd get applications -o custom-columns=\
'APP:.metadata.name,PROJECT:.spec.project,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' 2>/dev/null \
	  || { echo "Argo CD is not installed - run: make onprem-argocd"; exit 1; }

.PHONY: gitops-drift
gitops-drift: ## Anything running that Argo CD does NOT own (ADR-0009's detectable rule)
	@bash scripts/gitops-drift.sh

.PHONY: gitops-lock
gitops-lock: ## Regenerate Chart.lock for every wrapper chart (ADR-0010) - commit the result
	@set -eo pipefail; \
	for c in gitops/charts/*/; do \
	  echo "==> $$c"; \
	  helm dependency update "$$c"; \
	done; \
	echo; \
	echo "Chart.lock pins the upstream DIGEST, not just the version, so a re-tagged chart"; \
	echo "cannot change what is deployed. Commit the change on its own, with the reason."

.PHONY: gitops-render
gitops-render: ## Render a wrapper chart as Argo CD would (CHART=metrics-server ENV=onprem)
	@test -n "$(CHART)" || { echo "usage: make gitops-render CHART=<name> [ENV=onprem]"; exit 1; }
	@helm template $(CHART) gitops/charts/$(CHART) \
	  --namespace kube-system \
	  -f gitops/charts/$(CHART)/values.yaml \
	  -f gitops/environments/$(or $(ENV),onprem)/$(CHART).yaml

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
lint: ## Lint everything that can be linted - run this before pushing
	@set -eo pipefail; \
	echo "==> ansible playbooks parse"; \
	for p in ansible/playbooks/*.yml; do \
	  $(ANSIBLE_ENV) ansible-playbook "$$p" --syntax-check >/dev/null && echo "    ok   $$p"; \
	done; \
	echo "==> every YAML file parses"; \
	python3 -c 'import sys,glob,yaml; \
bad=0; \
fs=[f for p in ("ansible/**/*.yml","ansible/**/*.yaml","gitops/**/*.yaml","clusters/**/*.json") for f in glob.glob(p, recursive=True)]; \
[ (list(yaml.safe_load_all(open(f))), print("    ok  ", f)) if f.endswith((".yml",".yaml")) else None for f in fs ]' ; \
	echo "==> shell scripts parse"; \
	for s in scripts/*.sh; do bash -n "$$s" && echo "    ok   $$s"; done; \
	echo "==> the rest, where the tool is installed"; \
	command -v yamllint    >/dev/null && yamllint -s . || echo "    yamllint not installed, skipped"; \
	command -v terraform   >/dev/null && terraform -chdir=terraform fmt -check -recursive || true; \
	command -v ansible-lint >/dev/null && ansible-lint ansible/ || echo "    ansible-lint not installed, skipped"; \
	for c in $$(find gitops -name Chart.yaml -printf '%h\n' 2>/dev/null); do helm lint $$c; done
# NO pipes in the checks above, deliberately. `ansible-playbook --syntax-check | tail -2`
# reports tail's exit status, not ansible's - so a broken playbook passes a check that looks
# like it ran. That is how a YAML error reached main: the error was printed and the exit code
# was thrown away by the pipe.
