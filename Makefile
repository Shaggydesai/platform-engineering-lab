# platform-engineering-lab
#
# One entry point for everything. If a task is worth doing twice, it is a target here.
# Every cloud target has a matching destroy target, and `cost-check` is run at the end of
# every cloud session (ADR-0003).

SHELL := /bin/bash
.DEFAULT_GOAL := help
ENV ?= onprem

# A prerequisite on every target that runs a playbook, because of a real near-miss:
# `make onprem-up -- --tags gateway-api` ran the ENTIRE playbook - upgrading the CNI and
# removing kube-proxy - and only then failed with "No rule to make target '--tags'".
# make takes the extra words as goals and builds them IN ORDER, so the harm is done by the
# time it complains. There is no way to pass ansible flags through a make goal; use
# TAGS= and ARGS= below.
#
# This is a prerequisite rather than the first line of each recipe because prerequisites are
# built before the recipe runs, which is the whole point.
# Every variable this Makefile understands on the command line. Anything else is a typo.
KNOWN_VARS := TAGS ARGS CHART ENV CTX STORE_NAME PROBE_NS VAULT_NS VAULT_POD VAULT_KEYS \
              AWS_ALERT_EMAIL

.PHONY: _no-stray-flags
_no-stray-flags:
	@for g in $(MAKECMDGOALS); do case "$$g" in -*) \
	  printf '\033[31m%s\033[0m\n' "make cannot forward flags: '$$g' was read as a target."; \
	  printf '  Pass ansible flags with TAGS= or ARGS= instead, for example:\n'; \
	  printf '    make onprem-up TAGS=gateway-api\n'; \
	  printf '    make onprem-up ARGS="--check --diff"\n'; \
	  printf '  Stopping before anything runs.\n'; \
	  exit 1;; esac; done
# A MISSPELLED VARIABLE NAME IS SILENT, and that is the whole reason for this second guard.
#
# `make onprem-up TAggS=etcd-encryption` is a perfectly valid invocation: make accepts any
# NAME=value, binds it to a variable nothing reads, and runs the goal with TAGS empty - which
# means the ENTIRE playbook, on every node, instead of the four tasks that were asked for. It ran
# here on 2026-10-31, from a typo in an instruction, and it was harmless only because the
# playbook happens to be idempotent. The next such typo might be on a target that is not.
#
# This is the same shape as the flag guard above - `make onprem-up -- --tags X` silently building
# every word as a target - and the same fix: refuse what was not understood rather than proceed
# with a default nobody asked for.
#
# $(origin) distinguishes a variable set on the command line from one defined in this file, so
# the check applies only to what the caller typed.
	@bad=''; \
	for v in $(foreach v,$(.VARIABLES),$(if $(filter command line,$(origin $(v))),$(v))); do \
	  case " $(KNOWN_VARS) " in *" $$v "*) ;; *) bad="$$bad $$v";; esac; \
	done; \
	if [ -n "$$bad" ]; then \
	  printf '\033[31m%s\033[0m\n' "unknown variable(s) on the command line:$$bad"; \
	  printf '  make accepts any NAME=value, so a misspelled variable is SILENT - the goal runs\n'; \
	  printf '  with the real variable empty. For TAGS that means the whole playbook instead of\n'; \
	  printf '  the tags you asked for.\n\n'; \
	  printf '  understood here: $(KNOWN_VARS)\n'; \
	  printf '  Stopping before anything runs.\n'; \
	  exit 1; \
	fi

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
# TAGS=gateway-api limits a run to one play; ARGS="--check --diff" passes anything else.
# Both empty by default, so `make onprem-up` is unchanged.
PLAY_OPTS    := $(if $(TAGS),--tags $(TAGS),) $(ARGS)

# CTX=<kubectl context> for the Argo CD and GitOps helper targets below.
#
# WHY THIS APPEARED IN MODULE 08 and not before: until there was a second cluster, every
# `kubectl -n argocd ...` in this file acted on the only cluster there was. Now ~/.kube/config
# holds onprem-admin and gcp-platform, and current-context is whatever the last command set - so
# `make gitops-status` can describe a cluster the reader is not thinking about, and say nothing
# about which.
#
# The fix is deliberately small. These targets are READ-ONLY (status, a password, a refresh
# annotation), so a wrong cluster costs confusion rather than damage, and forcing an explicit
# context on every invocation would be friction out of proportion to that. Instead: the default
# is unchanged - current-context, exactly as before - and every target that uses it PRINTS which
# context it acted on. Ambiguity you can see is a different thing from ambiguity you cannot.
#
# Anything that writes gets the opposite treatment: the argocd role names its context explicitly
# and asserts it exists before installing anything (ADR-0020).
CTX ?=
KUBECTL      := kubectl $(if $(CTX),--context $(CTX),)
# Evaluated by the SHELL inside a recipe, not by make, so `make help` does not run kubectl.
CTX_SHOW      = $(if $(CTX),$(CTX),$$(kubectl config current-context 2>/dev/null || echo '?'))

.PHONY: onprem-ping
onprem-ping: ## Module 03 - can Ansible reach all three nodes?
	@$(ANSIBLE_ENV) ansible all -m ping

.PHONY: onprem-inventory
onprem-inventory: ## Module 03 - show the inventory derived from nodes.json
	@$(ANSIBLE_ENV) ansible-inventory --graph --vars

.PHONY: onprem-preflight
onprem-preflight: _no-stray-flags ## Module 03 - assert the golden image did its job (changes nothing)
	@$(PLAYBOOK) ansible/playbooks/cluster.yml --tags preflight $(ARGS)

.PHONY: onprem-check
onprem-check: _no-stray-flags ## Module 03 - dry run the whole cluster playbook (--check --diff)
	@$(PLAYBOOK) ansible/playbooks/cluster.yml --check --diff $(PLAY_OPTS)

.PHONY: onprem-up
onprem-up: _no-stray-flags ## Module 03 - build the whole on-prem cluster from nothing
	@$(PLAYBOOK) ansible/playbooks/cluster.yml $(PLAY_OPTS)

.PHONY: onprem-config
onprem-config: _no-stray-flags ## Module 03 - re-render the kubeadm config only
	@$(PLAYBOOK) ansible/playbooks/cluster.yml --tags config $(ARGS)

.PHONY: onprem-argocd
onprem-argocd: _no-stray-flags ## Module 04 - install/repair Argo CD and re-apply the GitOps seam
	@$(PLAYBOOK) ansible/playbooks/cluster.yml --tags argocd $(ARGS)

.PHONY: onprem-ca
onprem-ca: ## Export the internal CA so curl and browsers can verify the Gateway
	@mkdir -p .cache
	@kubectl --context $$(jq -r '.kubernetes.kube_context // "onprem-admin"' clusters/onprem/nodes.json 2>/dev/null || echo onprem-admin) \
	  -n cert-manager get secret platform-ca-tls -o jsonpath='{.data.ca\.crt}' \
	  | base64 -d > .cache/platform-ca.crt
	@printf 'wrote .cache/platform-ca.crt\n\n'
	@openssl x509 -in .cache/platform-ca.crt -noout -subject -enddate | sed 's/^/    /'
	@printf '\nVerify the Gateway with it:\n'
	@jq -r '.loadbalancer.gateway_hostnames[]? // .loadbalancer.gateway_hostname' clusters/onprem/nodes.json \
	  | sed 's|^|    curl -sS -o /dev/null -w "%{http_code}\\n" --cacert .cache/platform-ca.crt https://|'
	@printf '\nNOT in /tmp on purpose: a WSL restart clears /tmp, and the first thing that\n'
	@printf 'happens after a restart is wanting to check the Gateway still works.\n'

.PHONY: onprem-down
onprem-down: ## Destroy the on-prem cluster (keeps the VMs)
	@$(PLAYBOOK) ansible/playbooks/reset.yml

# ---------------------------------------------------------------- gitops

.PHONY: shopverse-secret
shopverse-secret: ## Create ShopVerse's credentials IN-CLUSTER (never in Git) - safe to re-run
	@set -eu; \
	ns=$$(yq -r '.spec.destination.namespace' gitops/clusters/onprem/apps/shopverse.yaml); \
	name=$$(yq -r '.secrets.existingSecret' gitops/environments/onprem/shopverse.yaml); \
	kubectl get namespace "$$ns" >/dev/null 2>&1 || kubectl create namespace "$$ns"; \
	if kubectl -n "$$ns" get secret "$$name" >/dev/null 2>&1; then \
	  printf '%s already exists in %s - nothing done.\n\n' "$$name" "$$ns"; \
	  printf 'NOT regenerated on purpose. mongo-password initialises the MongoDB root user on\n'; \
	  printf 'the volume FIRST BOOT ONLY. Replacing it later leaves the database expecting the\n'; \
	  printf 'old one, and every service fails to authenticate against a Mongo that is running\n'; \
	  printf 'and healthy - which reads like a connection-string bug for about an hour.\n\n'; \
	  printf 'To rotate deliberately, the volume goes too:\n'; \
	  printf '  kubectl -n %s delete secret %s\n' "$$ns" "$$name"; \
	  printf '  kubectl -n %s delete statefulset shopverse-mongodb\n' "$$ns"; \
	  printf '  kubectl -n %s delete pvc -l app.kubernetes.io/component=mongodb\n' "$$ns"; \
	  printf '  make shopverse-secret\n'; \
	  exit 0; \
	fi; \
	gen() { openssl rand -hex 24; }; \
	kubectl -n "$$ns" create secret generic "$$name" \
	  --from-literal=jwt-secret="$$(gen)" \
	  --from-literal=internal-token="$$(gen)" \
	  --from-literal=admin-email=admin@shopverse.local \
	  --from-literal=admin-password="$$(gen)" \
	  --from-literal=mongo-username=shopverse \
	  --from-literal=mongo-password="$$(gen)" >/dev/null; \
	printf 'created %s in %s\n\n' "$$name" "$$ns"; \
	printf 'Six random values, hex so they are URL-safe (mongo-password is embedded in a\n'; \
	printf 'connection string). They exist in this cluster and nowhere else: not in Git, not in\n'; \
	printf 'this terminal, not in any file. Read the admin login back with:\n'; \
	printf '  make shopverse-admin\n\n'; \
	printf 'This is Module 07 work done the cheap way on purpose (ADR-0016). A hand-made Secret\n'; \
	printf 'is a deliberate exception to ADR-0002 Rule 3, and the exception is that it cannot be\n'; \
	printf 'in Git. External Secrets replaces it; the chart already supports that path.\n'

.PHONY: vault-status
vault-status: ## Is Vault initialised, is it sealed, are the keys present
	@bash scripts/vault-ops.sh status

.PHONY: vault-init
vault-init: ## ONE TIME - initialise Vault and write the unseal keys to .cache/ (read the output)
	@bash scripts/vault-ops.sh init

.PHONY: vault-unseal
vault-unseal: ## Unseal Vault - needed after every cluster restart
	@bash scripts/vault-ops.sh unseal

.PHONY: vault-bootstrap
vault-bootstrap: ## Configure Vault's INSIDE - KV v2, Kubernetes auth, policy, the ESO role (idempotent)
# The fifth kind of state (ADR-0018 Decision 4): Vault's auth methods and policies live inside an
# application and are reachable only through its own API, so neither Terraform, Ansible nor Argo
# CD can own them. This is the explicit owner, and it is re-runnable so that being imperative
# costs as little as possible.
	@bash scripts/vault-bootstrap.sh

.PHONY: eso-check
eso-check: ## Write a FRESH value to Vault and prove it reaches a Kubernetes Secret
	@bash scripts/eso-check.sh

.PHONY: vault-seed-shopverse
vault-seed-shopverse: ## Copy ShopVerse's EXISTING six credentials into Vault (never regenerates)
# ADR-0018 Decision 5. mongo-password initialised MongoDB's root user on first boot only, so the
# migration copies rather than generates - a fresh value would leave every service authenticating
# against a database that still expects the old one, with MongoDB Running and Ready throughout.
	@bash scripts/vault-seed-shopverse.sh

# ---------------------------------------------------------------- gcp

GCP_GUARDRAILS := terraform/gcp/guardrails

.PHONY: cost-check
cost-check: ## ADR-0003 Decision 5 - is anything billable still running, in ANY project?
# This target did not exist until 2026-10-31, which is worse than it sounds: ADR-0003 says a
# session cannot end without it, the roadmap lists it as a Module 08 deliverable, and ADR-0019,
# docs/parking-lot.md and clusters/gcp/cluster.json all cite `make cost-check` by name. The
# script had been there since Module 00. Nothing invoked it, and every document that referred to
# it was describing something that would have printed "No rule to make target".
#
# A guardrail nobody can run is a guardrail in prose.
	@bash scripts/cost-check.sh

.PHONY: gcp-guardrails
gcp-guardrails: _no-stray-flags ## ADR-0003 gate - the ₹400 budget alert, BEFORE any cloud resource
# FOUR APIS ARE ENABLED BY GCLOUD BEFORE TERRAFORM RUNS, and they CANNOT be Terraform resources.
#
# A brand-new GCP project has almost nothing enabled. Terraform needs the Cloud Resource Manager
# API to manage `google_project_service` at all - and because the provider sets `billing_project`
# (ADR-0019, the X-Goog-User-Project fix), requests are attributed to that same new project. So
# Terraform needs the API enabled on the project in order to enable APIs on the project. It
# cannot bootstrap itself out of that, and the error it gives names the missing API without
# mentioning that the request was attributed to a project that is not the one being changed.
#
# `gcloud services enable` is idempotent, so this costs a second on every run and makes a fresh
# clone against a fresh project work without a manual step nobody wrote down. It was found the
# only way it could be: by pointing the guardrail at a project created five minutes earlier.
#
# A separate state and a separate target from the cluster, on purpose. `terraform apply` creates
# in dependency order and nothing would make a budget come first, so a cluster could exist for
# the length of a failed apply with no alert watching it. A guardrail applied alongside the thing
# it guards is not a guardrail (ADR-0003 Decision 3).
	@set -eu; \
	proj=$$(jq -r '.project_id' clusters/gcp/cluster.json); \
	if [ -z "$$proj" ] || [ "$$proj" = "null" ]; then \
	  printf '\033[31mproject_id is empty in clusters/gcp/cluster.json\033[0m\n\n'; \
	  printf 'Set it to the project this lab uses:\n'; \
	  printf '  gcloud projects list\n'; \
	  printf '  then edit clusters/gcp/cluster.json\n'; \
	  exit 1; \
	fi; \
	if [ -z "$${TF_VAR_billing_account:-}" ] && [ -r .cache/gcp-billing-account ]; then \
	  TF_VAR_billing_account=$$(cat .cache/gcp-billing-account); \
	  export TF_VAR_billing_account; \
	  printf 'billing account read from .cache/gcp-billing-account\n'; \
	fi; \
	if [ -z "$${TF_VAR_billing_account:-}" ]; then \
	  printf '\033[31mTF_VAR_billing_account is not set\033[0m\n\n'; \
	  printf 'It is kept OUT of Git because this repository is public and a billing account ID\n'; \
	  printf 'identifies a payment instrument (clusters/gcp/cluster.json explains). Set it with:\n\n'; \
	  printf '  export TF_VAR_billing_account="$$(gcloud billing accounts list \\\n'; \
	  printf "    --format='value(name)' | head -1 | cut -d/ -f2)\"\n\n"; \
	  printf '  echo "$$TF_VAR_billing_account"      # expect NNNNNN-NNNNNN-NNNNNN\n'; \
	  exit 1; \
	fi; \
	if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then \
	  printf '\033[31mno Application Default Credentials\033[0m\n\n'; \
	  printf 'Terraform authenticates with ADC, not a key file - there is no service-account JSON\n'; \
	  printf 'in this repository and there will not be (a downloaded key is a long-lived\n'; \
	  printf 'credential on a laptop, which ADR-0018 spent a module removing). Run:\n\n'; \
	  printf '  gcloud auth application-default login\n'; \
	  printf '  gcloud config set project %s\n' "$$proj"; \
	  exit 1; \
	fi; \
	mkdir -p .cache; \
	printf '%s' "$$TF_VAR_billing_account" > .cache/gcp-billing-account; \
	chmod 600 .cache/gcp-billing-account; \
	printf 'enabling the four bootstrap APIs (no-op if already on)\n'; \
	gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com \
	  cloudbilling.googleapis.com billingbudgets.googleapis.com \
	  --project="$$proj" --quiet || { \
	  printf '\033[31mcould not enable the bootstrap APIs on %s\033[0m\n' "$$proj"; \
	  printf 'Terraform cannot manage google_project_service without them, and it cannot enable\n'; \
	  printf 'them itself - that is the chicken-and-egg this step exists to break.\n'; \
	  exit 1; \
	}; \
	printf 'project        %s\n' "$$proj"; \
	printf 'billing acct   %s\n' "$$TF_VAR_billing_account"; \
	printf 'budget         %s %s, thresholds %s\n\n' \
	  "$$(jq -r '.budget.currency' clusters/gcp/cluster.json)" \
	  "$$(jq -r '.budget.amount_inr' clusters/gcp/cluster.json)" \
	  "$$(jq -rc '.budget.thresholds' clusters/gcp/cluster.json)"; \
	cd $(GCP_GUARDRAILS) && terraform init -input=false && terraform apply
	@printf '\nNow confirm it against the API rather than against Terraform:\n'
	@printf '  make gcp-guardrails-verify\n'

.PHONY: gcp-guardrails-verify
gcp-guardrails-verify: ## Read the budget back from the API and check it MATCHES cluster.json
# Terraform succeeding means the API accepted a request. This asks the API what it has, and then
# checks that what it has is what this repository asked for - amount AND thresholds. The first
# version only listed the budgets that existed and passed if there were any, which against a real
# account with two pre-existing ₹2500 budgets would have passed with ours missing entirely.
	@bash scripts/gcp-guardrails-verify.sh

# ---------------------------------------------------------------------------- AWS (Module 09)
#
# THE GUARDRAIL ARRIVES BEFORE THE SUBSTRATE, which is the whole of ADR-0003 Decision 3 applied to
# a cloud this repository has not built in yet. There is deliberately no `aws-up` here and no
# `_aws-preflight` either: a gate for a target that does not exist is dead code that rots, and the
# gate belongs in the same change as the cluster it refuses to build. What exists today is the
# alarm and the check that reads it back, both of which are usable against an empty account.
#
# AND THE REASON THIS MATTERS MORE ON AWS THAN ON GCP, recorded here because it is a money fact
# rather than a design preference: EKS has no free tier. GKE gives one zonal cluster's management
# fee for free; an EKS control plane is $0.10/hour from the moment it exists, so roughly $0.20/hour
# with two spot nodes, EBS and a load balancer. On the AWS free account plan there is also NO spend
# cap available - the limit that actually pauses resources requires the paid plan - so this budget
# alerts and stops nothing. `make aws-down` will be the control; this is what tells you it was
# forgotten.

AWS_GUARDRAIL_TF := terraform/aws/guardrails
AWS_ALERT_FILE   := .cache/aws-alert-email

.PHONY: aws-guardrails
aws-guardrails: _no-stray-flags ## ADR-0003 gate - the $5 budget alarm, BEFORE any AWS resource
# A SEPARATE STATE AND A SEPARATE TARGET from the cluster, for the reason the GCP equivalent above
# states: `terraform apply` creates in dependency order and nothing would make a budget come
# first, so a cluster could exist for the length of a failed apply with no alarm watching it.
#
# ONE EMAIL ADDRESS IS REQUIRED, and that is the AWS-specific part. Cloud Billing emails the
# billing account's admins by default, so the GCP guardrail can be applied with no recipient
# configured and still reach a human. AWS BUDGETS NOTIFY NOBODY: a notification with an empty
# subscriber list is accepted by the API and silent forever. So a missing address has to fail here
# rather than produce a budget that exists and watches nothing.
#
# The address is taken as a PLAIN STRING and wrapped into Terraform's list type here, deliberately.
# `TF_VAR_alert_emails` is a `list(string)`, so setting it by hand means exporting JSON
# (`'["you@example.com"]'`) - and an unquoted or single-element-without-brackets value fails inside
# Terraform with a type error about the variable, which reads like a bug in this repository.
#
# It is kept OUT OF GIT in .cache/ (gitignored), the same arrangement as the GCP billing account
# ID: this repository is public, and an address in a public repository is an address in a scraper's
# list.
	@set -eu; \
	command -v jq >/dev/null || { printf '\033[31mjq not installed\033[0m\n  make tools\n'; exit 1; }; \
	command -v aws >/dev/null || { \
	  printf '\033[31mthe AWS CLI is not installed\033[0m\n\n'; \
	  printf 'Install it, then configure credentials for the account this lab uses:\n'; \
	  printf '  aws configure        # region: %s\n' "$$(jq -r '.region' clusters/aws/cluster.json)"; \
	  exit 1; }; \
	if ! who=$$(aws sts get-caller-identity --output json 2>/dev/null); then \
	  printf '\033[31mthe AWS CLI has no working credentials\033[0m\n\n'; \
	  printf 'There are no access keys in this repository and there will not be - the same rule\n'; \
	  printf 'ADR-0018 enforced for GCP when it refused to download a service-account key. Run:\n\n'; \
	  printf '  aws configure        # region: %s\n' "$$(jq -r '.region' clusters/aws/cluster.json)"; \
	  exit 1; \
	fi; \
	acct=$$(printf '%s' "$$who" | jq -r '.Account'); \
	arn=$$(printf '%s' "$$who" | jq -r '.Arn'); \
	case "$$arn" in \
	  *:root) \
	    if [ -n "$$(aws configure get aws_session_token 2>/dev/null)" ]; then \
	      printf '\033[33mroot, but a SHORT-LIVED session rather than a key\033[0m\n\n'; \
	      printf '  %s\n\n' "$$arn"; \
	      printf 'Allowed. `aws login` issues root credentials on this account and there is no\n'; \
	      printf 'other identity available - IAM Identity Center is not supported on the free plan\n'; \
	      printf 'and the IAM console redirects (ADR-0024). What makes it acceptable is that this\n'; \
	      printf 'expires in 12 hours and came through a browser session with MFA on it.\n\n'; \
	    else \
	      printf '\033[31ma root ACCESS KEY - refusing\033[0m\n\n'; \
	      printf '  %s\n\n' "$$arn"; \
	      printf 'No session token, so these are long-lived root credentials sitting in a file.\n'; \
	      printf 'Root cannot be restricted by any policy - it can change the payment method,\n'; \
	      printf 'spend the credits and close the account - and this is the one AWS credential\n'; \
	      printf 'whose leak has no recovery story. It should not exist at all (ADR-0024).\n\n'; \
	      printf 'Delete it, then get a short-lived one through the browser instead:\n\n'; \
	      printf '  aws login --profile platform-lab\n'; \
	      printf '  export AWS_PROFILE=platform-lab\n\n'; \
	      printf '  https://console.aws.amazon.com/iam/home#/security_credentials\n'; \
	      exit 1; \
	    fi ;; \
	esac; \
	case "$$arn" in \
	  *:assumed-role/*) : ;; \
	  *) \
	    printf '\033[33mthese are an IAM USER'"'"'s own credentials, not an assumed role\033[0m\n\n'; \
	    printf '  %s\n\n' "$$arn"; \
	    printf 'Not refused - it works. But it means a LONG-LIVED ACCESS KEY on this laptop is the\n'; \
	    printf 'credential, which is what ADR-0018 removed from the GCP path and ADR-0024 says is\n'; \
	    printf 'unnecessary here: this account issues 12-hour credentials through the browser.\n\n'; \
	    printf '  aws login --profile platform-lab\n'; \
	    printf '  export AWS_PROFILE=platform-lab\n'; \
	    printf '  aws sts get-caller-identity        # expect assumed-role/..., not user/...\n\n'; \
	    printf 'If AWS_PROFILE is already set, this is usually an expired session - aws login again.\n\n' ;; \
	esac; \
	email="$${AWS_ALERT_EMAIL:-}"; \
	if [ -z "$$email" ] && [ -r $(AWS_ALERT_FILE) ]; then \
	  email=$$(cat $(AWS_ALERT_FILE)); \
	  printf 'alert address read from %s\n' '$(AWS_ALERT_FILE)'; \
	fi; \
	if [ -z "$$email" ]; then \
	  printf '\033[31mno alert email address\033[0m\n\n'; \
	  printf 'AWS Budgets notify NOBODY by default, so a budget without a subscriber is a\n'; \
	  printf 'guardrail that cannot warn you - and it looks correct in the console. Set one:\n\n'; \
	  printf '  make aws-guardrails AWS_ALERT_EMAIL=you@example.com\n\n'; \
	  printf 'It is remembered in %s (gitignored) so the next run needs no argument.\n' '$(AWS_ALERT_FILE)'; \
	  exit 1; \
	fi; \
	printf '\n'; \
	printf '  account   %s\n' "$$acct"; \
	printf '  region    %s   \033[2m(immaterial - Budgets is account-scoped)\033[0m\n' "$$(jq -r '.region' clusters/aws/cluster.json)"; \
	printf '  budget    %s %s, thresholds %s\n' \
	  "$$(jq -r '.budget.currency' clusters/aws/cluster.json)" \
	  "$$(jq -r '.budget.amount_usd' clusters/aws/cluster.json)" \
	  "$$(jq -c '[.budget.thresholds[] * 100]' clusters/aws/cluster.json)"; \
	printf '  alerts    %s\n\n' "$$email"; \
	mkdir -p .cache; \
	printf '%s' "$$email" > $(AWS_ALERT_FILE); \
	chmod 600 $(AWS_ALERT_FILE); \
	TF_VAR_alert_emails=$$(jq -nc --arg e "$$email" '[$$e]'); export TF_VAR_alert_emails; \
	cd $(AWS_GUARDRAIL_TF) && terraform init -input=false && terraform apply

.PHONY: aws-guardrails-verify
aws-guardrails-verify: ## Read the budget back from the API and check it MATCHES cluster.json
# Three questions the GCP equivalent asks in two, because AWS splits them across three API calls:
# does our budget exist at the amount cluster.json names, are the thresholds on ACTUAL spend, and
# IS ANYONE SUBSCRIBED. The third has no GCP counterpart and is the one that decides whether this
# guardrail can warn you at all.
	@bash scripts/aws-guardrails-verify.sh

AWS_TF := terraform/aws

.PHONY: _aws-preflight
_aws-preflight:
	@set -eu; \
	command -v jq >/dev/null || { printf '\033[31mjq not installed\033[0m\n  make tools\n'; exit 1; }; \
	command -v aws >/dev/null || { printf '\033[31mthe AWS CLI is not installed\033[0m\n'; exit 1; }; \
	if ! aws sts get-caller-identity >/dev/null 2>&1; then \
	  printf '\033[31mno working AWS credentials\033[0m\n\n'; \
	  printf 'They expire after 12 hours (ADR-0024). Get a new session:\n\n'; \
	  printf '  aws login --profile platform-lab\n'; \
	  printf '  export AWS_PROFILE=platform-lab\n'; \
	  exit 1; \
	fi; \
	if [ ! -r "$$(eval echo $$(jq -r '.ssh.public_key_file' clusters/aws/cluster.json))" ]; then \
	  printf '\033[31mno SSH public key at %s\033[0m\n\n' "$$(jq -r '.ssh.public_key_file' clusters/aws/cluster.json)"; \
	  printf 'Terraform puts it on every node and Ansible logs in with it. Same key the laptop\n'; \
	  printf 'uses (clusters/onprem/nodes.json). Generate one if it is genuinely absent:\n\n'; \
	  printf '  ssh-keygen -t ed25519 -C platform-engineering-lab\n'; \
	  exit 1; \
	fi

.PHONY: aws-up
aws-up: _no-stray-flags _aws-preflight ## Build 3 spot EC2 nodes (REFUSES without the budget guardrail)
# THE GUARDRAIL CHECK IS A PREREQUISITE, NOT A REMINDER - the same arrangement as gcp-up, and it
# matters more here: this account has NO CREDITS (ADR-0003 Decision 6), so the alarm is the only
# thing between a forgotten cluster and a card.
	@set -eu; \
	printf 'checking the guardrail before creating anything billable...\n'; \
	set +e; bash scripts/aws-guardrails-verify.sh | sed 's/^/  /'; gv=$${PIPESTATUS[0]}; set -e; \
	if [ "$$gv" -eq 2 ]; then \
	  printf '\n\033[31mthe guardrail could not be CHECKED - refusing anyway\033[0m\n\n'; \
	  printf 'It may well be fine. "I could not look" is not "it is missing", and the output\n'; \
	  printf 'above says which - but neither is a basis for creating something billable.\n'; \
	  exit 1; \
	elif [ "$$gv" -ne 0 ]; then \
	  printf '\n\033[31mthe budget alarm is missing or does not match cluster.json\033[0m\n\n'; \
	  printf 'ADR-0003 Decision 3: the alarm exists BEFORE the first resource.\n'; \
	  printf '  make aws-guardrails AWS_ALERT_EMAIL=you@example.com\n'; \
	  exit 1; \
	fi; \
	printf '\nregion    %s / %s\n' "$$(jq -r '.region' clusters/aws/cluster.json)" "$$(jq -r '.availability_zone' clusters/aws/cluster.json)"; \
	printf 'nodes     1 x %s control plane + %s x %s workers, spot=%s\n' \
	  "$$(jq -r '.nodes.control_plane.instance_type' clusters/aws/cluster.json)" \
	  "$$(jq -r '.nodes.workers.count' clusters/aws/cluster.json)" \
	  "$$(jq -r '.nodes.workers.instance_type' clusters/aws/cluster.json)" \
	  "$$(jq -r '.nodes.spot' clusters/aws/cluster.json)"; \
	printf 'cost      real money - this account has no credits (ADR-0003 Decision 6)\n\n'
	@cd $(AWS_TF) && terraform init -input=false && terraform apply

.PHONY: aws-wait
aws-wait: _aws-preflight ## Wait for cloud-init to finish running the image scripts on every node
# WITHOUT THIS, ANSIBLE RACES THE BOOT. preflight asserts what the image scripts produce - swap
# off, br_netfilter loaded, the right kubeadm - and on a node thirty seconds from passing them it
# fails every one, which reads as a broken image rather than as impatience. That is the
# "transient state read once" shape this project has already paid for twice (ADR-0021).
	@set -eu; \
	user=$$(jq -r '.ssh.user' clusters/aws/cluster.json); \
	key=$$(eval echo $$(jq -r '.ssh.public_key_file' clusters/aws/cluster.json) | sed 's/\.pub$$//'); \
	ips=$$(cd $(AWS_TF) && terraform output -json nodes | jq -r '.[].public_ip'); \
	[ -n "$$ips" ] || { printf '\033[31mno nodes in the Terraform state - run make aws-up\033[0m\n'; exit 1; }; \
	for ip in $$ips; do \
	  printf '  %s ' "$$ip"; \
	  ok=no; \
	  for i in $$(seq 1 60); do \
	    if ssh -i "$$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	           -o ConnectTimeout=5 -o LogLevel=ERROR "$$user@$$ip" \
	           'test -f /var/lib/cloud/image-ready' 2>/dev/null; then ok=yes; break; fi; \
	    printf '.'; sleep 10; \
	  done; \
	  if [ "$$ok" = yes ]; then printf ' \033[32mimage ready\033[0m\n'; \
	  else printf ' \033[31mNOT ready after 10 minutes\033[0m\n'; \
	       printf '      ssh -i %s %s@%s '"'"'sudo tail -50 /var/log/image-build.log'"'"'\n' "$$key" "$$user" "$$ip"; \
	       exit 1; fi; \
	done; \
	printf '\nEvery node ran the same four scripts the Packer image bakes for the laptop\n'; \
	printf '(ADR-0025). Next:  make aws-cluster\n'

.PHONY: aws-down
aws-down: _no-stray-flags ## Destroy the AWS cluster, then prove nothing is left
# ANYTHING A CONTROLLER INSIDE THE CLUSTER CREATED MUST GO FIRST. ADR-0021 learned that twice on
# GCP - a forwarding rule, then an orphaned Persistent Disk - and the rule is not GCP-specific:
# Terraform has no record of a load balancer the ingress layer asked for, and destroying the
# cluster removes the controller that would clean it up.
#
# Best-effort and non-fatal, like the GCP one: refusing to destroy a billable cluster because a
# cleanup step could not run would invert the point. cost-check below is the actual answer.
	@set -u; \
	if kubectl config get-contexts -o name 2>/dev/null | grep -qx aws-platform \
	   && kubectl --context aws-platform -n argocd get applications >/dev/null 2>&1; then \
	  printf '==> taking in-cluster cloud objects down BEFORE the cluster\n'; \
	  kubectl --context aws-platform -n argocd delete application platform-ingress \
	    --wait=true --timeout=180s 2>&1 | sed 's/^/    /' || true; \
	  kubectl --context aws-platform -n argocd get applications \
	    -o jsonpath='{range .items[?(@.spec.project=="tenants")]}{.metadata.name}{"\n"}{end}' \
	    2>/dev/null | grep . | while read -r a; do \
	      kubectl --context aws-platform -n argocd delete application "$$a" \
	        --wait=true --timeout=120s 2>&1 | sed 's/^/    /' || true; \
	    done; \
	  kubectl --context aws-platform delete pvc -A --all --wait=true --timeout=180s 2>&1 | sed 's/^/    /' || true; \
	  reg=$$(jq -r '.region' clusters/aws/cluster.json); \
	  printf '\n    waiting for load balancers to disappear from AWS\n'; \
	  for i in $$(seq 1 30); do \
	    n=$$(timeout 30 aws elbv2 describe-load-balancers --region "$$reg" \
	           --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null | grep -c . || true); \
	    m=$$(timeout 30 aws elb describe-load-balancers --region "$$reg" \
	           --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null | grep -c . || true); \
	    if [ "$$n" = "0" ] && [ "$$m" = "0" ]; then printf '    \033[32mnone left\033[0m\n\n'; break; fi; \
	    printf '    %s still there (%ss)\n' "$$((n + m))" "$$((i * 10))"; sleep 10; \
	  done; \
	else \
	  printf '==> no aws-platform context with Applications - nothing in-cluster to clean up first\n\n'; \
	fi
	@cd $(AWS_TF) && terraform destroy
	@printf '\n==> and now the question terraform cannot answer\n'
	@$(MAKE) --no-print-directory cost-check

GCP_TF := terraform/gcp

.PHONY: _gcp-preflight
_gcp-preflight:
	@set -eu; \
	proj=$$(jq -r '.project_id' clusters/gcp/cluster.json); \
	if [ -z "$$proj" ] || [ "$$proj" = "null" ]; then \
	  printf '\033[31mproject_id is empty in clusters/gcp/cluster.json\033[0m\n'; exit 1; fi; \
	if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then \
	  printf '\033[31mno Application Default Credentials\033[0m\n'; \
	  printf '  gcloud auth application-default login\n'; exit 1; fi

.PHONY: gcp-up
gcp-up: _no-stray-flags _gcp-preflight ## Build the zonal GKE cluster (REFUSES without the budget guardrail)
# The guardrail check is a PREREQUISITE, not a reminder. ADR-0003 Decision 3 says the budget
# alarm exists before the first cloud resource, and for six modules that has been a sentence in a
# document which someone has to remember at the one moment they are keen to get on with it.
# Here it is the difference between this target running and not running.
	@set -eu; \
	printf 'checking the guardrail before creating anything billable...\n'; \
	set +e; bash scripts/gcp-guardrails-verify.sh | sed 's/^/  /'; gv=$${PIPESTATUS[0]}; set -e; \
	if [ "$$gv" -eq 2 ]; then \
	  printf '\n\033[31mthe guardrail could not be CHECKED - refusing anyway\033[0m\n\n'; \
	  printf 'It may well be fine. "I could not look" is not "it is missing", and the output\n'; \
	  printf 'above says which - but neither is a basis for creating something billable.\n'; \
	  exit 1; \
	elif [ "$$gv" -ne 0 ]; then \
	  printf '\n\033[31mthe budget guardrail is missing or does not match cluster.json\033[0m\n\n'; \
	  printf 'ADR-0003 Decision 3: the alarm exists BEFORE the first resource. Refusing to build\n'; \
	  printf 'a cluster that nothing is watching.\n  make gcp-guardrails\n'; \
	  exit 1; \
	fi; \
	proj=$$(jq -r '.project_id' clusters/gcp/cluster.json); \
	printf 'enabling compute and container (no-op if already on)\n'; \
	gcloud services enable compute.googleapis.com container.googleapis.com \
	  --project="$$proj" --quiet; \
	printf '\nzone      %s\n' "$$(jq -r '.zone' clusters/gcp/cluster.json)"; \
	printf 'nodes     %s x %s, spot=%s\n\n' \
	  "$$(jq -r '.nodes.count' clusters/gcp/cluster.json)" \
	  "$$(jq -r '.nodes.machine_type' clusters/gcp/cluster.json)" \
	  "$$(jq -r '.nodes.spot' clusters/gcp/cluster.json)"; \
	cd $(GCP_TF) && terraform init -input=false && terraform apply
	@printf '\nLayers 0 and 1 are up, and Google owns everything in them. Next:\n'
	@printf '  make gcp-kubeconfig   name the context gcp-platform\n'
	@printf '  make gcp-argocd       Layer 2 - the SAME ansible role as on-prem (ADR-0020)\n'
	@printf '  make gcp-smoke        read back what the cluster actually is\n\n'
	@printf 'And the one that ends the session, whatever else happens (ADR-0003 Decision 5):\n'
	@printf '  make gcp-down\n'

.PHONY: gcp-down
gcp-down: _no-stray-flags _gcp-preflight ## Destroy the GKE cluster, then prove nothing is left
# THE INGRESS COMES DOWN FIRST, AND THIS IS THE ONE ORDERING IN THIS REPOSITORY WITH MONEY ON IT.
#
# The Gateway is reconciled by the GKE controller into a Google global external Application Load
# Balancer - a forwarding rule, a target proxy, a URL map, a backend service, a health check and
# a NEG per backend. TERRAFORM DID NOT CREATE ANY OF THEM AND HAS NO RECORD OF THEM. Destroying
# the cluster destroys the controller that owns them, which is the opposite of destroying them:
# the thing that would clean up is removed first, and GKE's cluster-delete cleanup is documented
# as best-effort for load balancers rather than guaranteed.
#
# So: delete the Application, let its finalizer cascade to the Gateway, and WAIT for GCP to
# report the forwarding rule gone. Then destroy the cluster. ADR-0021.
#
# This is deliberately best-effort and non-fatal. A cluster that is already gone, a kubeconfig
# that no longer resolves, or an Argo CD that was never installed must not stop a teardown -
# refusing to destroy a billable cluster because a cleanup step could not run would be the exact
# inversion of the point. Whatever happens here, cost-check below is the actual answer.
	@set -u; \
	if kubectl config get-contexts -o name 2>/dev/null | grep -qx gcp-platform \
	   && kubectl --context gcp-platform -n argocd get application platform-ingress >/dev/null 2>&1; then \
	  printf '==> taking the load balancer down BEFORE the cluster\n'; \
	  printf '    the Gateway is a Google load balancer that terraform never created, so\n'; \
	  printf '    destroying the cluster first removes the controller that would clean it up\n\n'; \
	  kubectl --context gcp-platform -n argocd delete application platform-ingress \
	    --wait=true --timeout=180s 2>&1 | sed 's/^/    /' || \
	    printf '    %bcould not delete the Application - continuing, cost-check is the check%b\n' '\033[33m' '\033[0m'; \
	  proj=$$(jq -r '.project_id' clusters/gcp/cluster.json); \
	  printf '\n    waiting for the forwarding rule to disappear from GCP\n'; \
	  gone=no; \
	  for i in $$(seq 1 30); do \
	    n=$$(timeout 30 gcloud compute forwarding-rules list --project="$$proj" \
	           --format='value(name)' 2>/dev/null | grep -c . || true); \
	    if [ "$$n" = "0" ]; then gone=yes; break; fi; \
	    printf '    %s forwarding rule(s) still there (%ss)\n' "$$n" "$$((i * 10))"; \
	    sleep 10; \
	  done; \
	  if [ "$$gone" = yes ]; then \
	    printf '    %bno forwarding rules left - the load balancer is gone%b\n\n' '\033[32m' '\033[0m'; \
	  else \
	    printf '\n    %bforwarding rules are STILL present after 5 minutes%b\n' '\033[31m' '\033[0m'; \
	    printf '    Destroying the cluster now may ORPHAN them, and an orphaned forwarding rule\n'; \
	    printf '    is billed hourly forever. cost-check at the end of this run will list them\n'; \
	    printf '    with the command to remove each one. DO NOT skip reading it.\n\n'; \
	  fi; \
	else \
	  printf '==> no platform-ingress Application to take down first\n'; \
	  printf '    %snothing created a load balancer, so there is nothing to orphan%s\n\n' '' ''; \
	fi
# AND THE DISKS, which is the SAME ordering bug one object over, found by cost-check on 2026-11-02.
#
# That run destroyed the cluster cleanly and left `pvc-5f355018-...` behind: a 5 GB Persistent Disk,
# unattached, billing. ADR-0021 fixed the ordering for the load balancer and did not generalise it,
# so the rule it discovered got applied once rather than understood.
#
# The shape is identical. The PD CSI driver deletes the disk when the PVC is deleted, because the
# StorageClass reclaim policy is Delete - but destroying the cluster removes that driver, so the
# disk outlives the only thing that would have removed it. Terraform never created it and has no
# record of it, which is why `Destroy complete! Resources: 4 destroyed` was true and incomplete.
#
# THE EXTRA WRINKLE IS WHOSE PVC IT IS, and it is nobody's in the GitOps sense. MongoDB's PVC comes
# from the StatefulSet's volumeClaimTemplate, so Argo CD never created it and will not prune it;
# deleting the Application removes the StatefulSet and deliberately leaves the data behind. On a
# cluster about to be destroyed that guarantee is exactly backwards.
#
# So: delete the tenant Applications, which stops the pods holding the pvc-protection finalizer,
# then delete the PVCs, then WAIT for GCP to report no unattached disks. Best-effort and non-fatal,
# like the block above: cost-check at the end is the actual answer.
	@set -u; \
	if kubectl config get-contexts -o name 2>/dev/null | grep -qx gcp-platform \
	   && kubectl --context gcp-platform -n argocd get applications >/dev/null 2>&1; then \
	  tapps=$$(kubectl --context gcp-platform -n argocd get applications \
	             -o jsonpath='{range .items[?(@.spec.project=="tenants")]}{.metadata.name}{"\n"}{end}' \
	             2>/dev/null | grep -c . || true); \
	  pvcs=$$(kubectl --context gcp-platform get pvc -A --no-headers 2>/dev/null | grep -c . || true); \
	  if [ "$$tapps" != "0" ] || [ "$$pvcs" != "0" ]; then \
	    printf '==> taking the tenant PVCs down BEFORE the cluster\n'; \
	    printf '    a StatefulSet volumeClaimTemplate PVC is owned by nothing in Git, and the CSI\n'; \
	    printf '    driver that deletes its Persistent Disk dies with the cluster (ADR-0021)\n\n'; \
	    kubectl --context gcp-platform -n argocd get applications \
	      -o jsonpath='{range .items[?(@.spec.project=="tenants")]}{.metadata.name}{"\n"}{end}' \
	      2>/dev/null | grep . | while read -r a; do \
	        kubectl --context gcp-platform -n argocd delete application "$$a" \
	          --wait=true --timeout=120s 2>&1 | sed 's/^/    /' || true; \
	      done; \
	    kubectl --context gcp-platform delete pvc -A --all \
	      --wait=true --timeout=180s 2>&1 | sed 's/^/    /' || \
	      printf '    %bcould not delete every PVC - continuing, cost-check is the check%b\n' '\033[33m' '\033[0m'; \
	    proj=$$(jq -r '.project_id' clusters/gcp/cluster.json); \
	    printf '\n    waiting for the Persistent Disks to disappear from GCP\n'; \
	    gone=no; \
	    for i in $$(seq 1 18); do \
	      n=$$(timeout 30 gcloud compute disks list --project="$$proj" \
	             --filter='-users:*' --format='value(name)' 2>/dev/null | grep -c . || true); \
	      if [ "$$n" = "0" ]; then gone=yes; break; fi; \
	      printf '    %s unattached disk(s) still there (%ss)\n' "$$n" "$$((i * 10))"; \
	      sleep 10; \
	    done; \
	    if [ "$$gone" = yes ]; then \
	      printf '    %bno unattached disks left%b\n\n' '\033[32m' '\033[0m'; \
	    else \
	      printf '\n    %bunattached disks are STILL present%b\n' '\033[31m' '\033[0m'; \
	      printf '    cost-check at the end lists each with its remove command. DO NOT skip it.\n\n'; \
	    fi; \
	  else \
	    printf '==> no tenant Applications and no PVCs - nothing to orphan a disk\n\n'; \
	  fi; \
	fi
	@cd $(GCP_TF) && terraform destroy
# cost-check runs REGARDLESS of what destroy reported, which is the point of having it.
# `terraform destroy` succeeding means Terraform removed what it knew about - it says nothing
# about a disk it never created, or a resource an earlier failed apply orphaned. ADR-0003
# Decision 5: a session cannot end without this.
	@printf '\n==> and now the question terraform cannot answer\n'
	@$(MAKE) --no-print-directory cost-check

.PHONY: gcp-kubeconfig
gcp-kubeconfig: _gcp-preflight ## Point kubectl at the GKE cluster, under an unmistakable context name
	@set -eu; \
	proj=$$(jq -r '.project_id' clusters/gcp/cluster.json); \
	zone=$$(jq -r '.zone' clusters/gcp/cluster.json); \
	gcloud container clusters get-credentials platform --zone "$$zone" --project "$$proj"; \
	auto="gke_$${proj}_$${zone}_platform"; \
	kubectl config delete-context gcp-platform >/dev/null 2>&1 || true; \
	kubectl config rename-context "$$auto" gcp-platform; \
	printf '\ncontext renamed to \033[36mgcp-platform\033[0m\n'; \
	printf 'The generated name (%s) is long enough that the\n' "$$auto"; \
	printf 'prompt truncates it, and a truncated context name next to onprem-admin is how a\n'; \
	printf 'command lands on the wrong cluster.\n\n'; \
	stale=$$(kubectl config get-contexts -o name | grep '^gke_' | grep -v "_$${proj}_" || true); \
	if [ -n "$$stale" ]; then \
	  printf '\033[33mcontexts pointing at a GKE cluster that is not this one:\033[0m\n'; \
	  printf '%s\n' "$$stale" | sed 's/^/    /'; \
	  printf '  A context for a DELETED cluster still appears here and still looks selectable.\n'; \
	  printf '  Remove each with:  kubectl config delete-context NAME\n\n'; \
	fi; \
	kubectl config get-contexts

# ---------------------------------------------------------------- Layer 2 on GCP
#
# THE SAME ROLE AS ON-PREM, against the gcp-platform context (ADR-0020). ansible/playbooks/gcp.yml
# is one play long, and ansible/inventory/gcp.py has one host, which is this workstation - there
# is no control-plane node on GKE to log into, and the argocd role never needed one because every
# task in it already delegated to localhost.
#
# No guardrail gate on these two, deliberately. ADR-0003 Decision 3 guards the creation of
# BILLABLE resources, and installing Argo CD creates none - the cluster is already running and
# already billing by the time these can work. The gate belongs on `make gcp-up`, which is where
# it is. A gate repeated everywhere becomes a gate nobody reads.
#
# -i overrides ansible.cfg's inventory, which names the on-prem one. It is passed explicitly on
# both targets rather than being switched by ENV, because a wrong inventory here would run Layer
# 2 against the wrong cluster, and `make gcp-argocd` should not depend on a variable's default
# being right.
GCP_PLAY := $(PLAYBOOK) -i ansible/inventory/gcp.py ansible/playbooks/gcp.yml

.PHONY: gcp-inventory
gcp-inventory: ## Show the GCP inventory derived from clusters/gcp/cluster.json
	@$(ANSIBLE_ENV) ansible-inventory -i ansible/inventory/gcp.py --graph --vars

.PHONY: gcp-argocd-check
gcp-argocd-check: _no-stray-flags ## Dry run Layer 2 on GKE (--check --diff, changes nothing)
	@$(GCP_PLAY) --check --diff $(ARGS)

.PHONY: gcp-argocd
gcp-argocd: _no-stray-flags ## Install Argo CD on GKE and apply the seam (needs gcp-up + gcp-kubeconfig)
	@set -eu; \
	if ! kubectl config get-contexts -o name | grep -qx gcp-platform; then \
	  printf '\033[31mno kubectl context named gcp-platform\033[0m\n\n'; \
	  printf 'The role asserts this too and prints the contexts that DO exist, but failing here\n'; \
	  printf 'costs a second instead of a playbook run. In order:\n'; \
	  printf '  make gcp-up           the cluster (refuses without the budget guardrail)\n'; \
	  printf '  make gcp-kubeconfig   creates and names this context\n'; \
	  exit 1; \
	fi
	@$(GCP_PLAY) $(ARGS)

# ---------------------------------------------------------------- the GCP secret backend
#
# A THIRD Terraform state, and the reason is lifetime rather than tidiness. terraform/gcp holds a
# cluster destroyed at the end of every session; this holds the identity ShopVerse's secrets are
# read with, and the secret itself, and both SURVIVE `make gcp-down` on purpose. Regenerating
# credentials every session would hand a fresh mongo-password to a database initialised with the
# previous one - the Module 07 failure, presenting as a Running, Ready MongoDB that refuses every
# connection (ADR-0018 Decision 5).
#
# No guardrail gate on these: nothing here is billable within the free tier (one service account,
# three IAM bindings, one secret version of six free). The gate belongs on `make gcp-up`.
GCP_SECRETS_TF := terraform/gcp/secrets

.PHONY: gcp-secrets
gcp-secrets: _no-stray-flags _gcp-preflight ## The GCP secret backend - identity, IAM, and an EMPTY secret
# Terraform creates the SHAPE and never the CONTENT. A google_secret_manager_secret_version with
# secret_data set would write all six ShopVerse credentials into terraform.tfstate in plaintext -
# `sensitive` suppresses a value in OUTPUT, not in state - so a module whose whole subject is "no
# secrets in Git" would have put them on disk beside the repository. Values go in with
# `make gcp-secrets-seed`, generated and streamed on stdin.
	@set -eu; \
	proj=$$(jq -r '.project_id' clusters/gcp/cluster.json); \
	printf 'enabling secretmanager and iam (no-op if already on)\n'; \
	printf '  not Terraform resources, for the reason ADR-0019 Decision 1c gives: an API that\n'; \
	printf '  must exist before Terraform can refresh its own state cannot be managed by it.\n'; \
	gcloud services enable secretmanager.googleapis.com iam.googleapis.com \
	  --project="$$proj" --quiet; \
	printf '\nproject   %s\n\n' "$$proj"; \
	cd $(GCP_SECRETS_TF) && terraform init -input=false && terraform apply
	@printf '\nThe box exists and is EMPTY. Next:\n'
	@printf '  make gcp-secrets-seed     generate the six values and put them in\n'
	@printf '  make gcp-secrets-verify   read the whole arrangement back out of the API\n'

.PHONY: gcp-secrets-seed
gcp-secrets-seed: _gcp-preflight ## Generate ShopVerse's six credentials into Secret Manager (refuses to overwrite)
	@bash scripts/gcp-secrets.sh seed

.PHONY: gcp-secrets-verify
gcp-secrets-verify: _gcp-preflight ## Read the secret backend back out of the API - identity, grant, binding, payload
# Four separate questions, and the third is the one nobody thinks to ask: a project-wide
# secretAccessor would also make the ExternalSecret work, and would let External Secrets read
# every secret in the project. "It works" is not the question.
	@bash scripts/gcp-secrets.sh verify

.PHONY: gcp-secrets-destroy
gcp-secrets-destroy: _no-stray-flags _gcp-preflight ## Destroy the secret backend INCLUDING every version of the secret
	@printf '\033[31mThis destroys the secret and every version of it.\033[0m\n'
	@printf 'The six credentials exist nowhere else - not in Git, not in Terraform state, not on\n'
	@printf 'this disk. That is recoverable (reseed, and let ShopVerse build a fresh database) but\n'
	@printf 'it is NOT recoverable if anything on GKE is holding data you want to keep.\n\n'
	@cd $(GCP_SECRETS_TF) && terraform destroy

.PHONY: gcp-address
gcp-address: ## What address did the cloud give the Gateway, and the hosts lines to match
# ON-PREM THIS TARGET WOULD BE POINTLESS, which is the whole content of ADR-0021's address
# finding. There the address is written in clusters/onprem/nodes.json, pinned in the overlay, and
# `make hosts` writes it from the file. It is a configuration choice and it does not move.
#
# Here it is an ALLOCATION: the load balancer is given a public address when it is created, a
# different one every session, and the only place that fact exists is the live Gateway's status.
# Pinning it would mean reserving a static address, which GCP bills while unattached - so the
# address moves and the name follows it.
#
# THE HOSTNAMES COME FROM THE GCP OVERLAY, not from clusters/onprem/nodes.json. The first version
# of this target read the on-prem file - the names are currently the same on both substrates, so
# it would have worked and been wrong, which is the same category error that moved the Argo CD
# pins to clusters/platform.json. A GCP target that reads an on-prem file is one divergence away
# from printing instructions for the wrong cluster.
	@set -eu; \
	addr=$$(kubectl --context gcp-platform -n platform-ingress get gateway platform \
	          -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true); \
	if [ -z "$$addr" ]; then \
	  printf '\033[33mthe Gateway has no address yet\033[0m\n\n'; \
	  prog=$$(kubectl --context gcp-platform -n platform-ingress get gateway platform \
	            -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}/{.status.conditions[?(@.type=="Programmed")].message}' 2>/dev/null || true); \
	  printf 'Programmed: %s\n\n' "$${prog:-(no Gateway object at all)}"; \
	  printf 'A global load balancer takes MINUTES to provision, not seconds - longer than\n'; \
	  printf 'anything Cilium does on-prem. If it stays empty:\n'; \
	  printf '  kubectl --context gcp-platform -n platform-ingress describe gateway platform\n'; \
	  printf '  make gitops-status CTX=gcp-platform\n'; \
	  exit 1; \
	fi; \
	printf 'Gateway address  \033[36m%s\033[0m\n\n' "$$addr"; \
	printf 'It is EPHEMERAL - a different one next session (ADR-0021). The names are stable, so\n'; \
	printf 'point them at it. In WSL:\n\n'; \
	for h in $$(yq -r '[.gateway.hostname] + [.routes[].hostname] | .[] | select(. != null and . != "")' \
	              gitops/environments/gcp/platform-ingress.yaml); do \
	  printf '    %s  %s\n' "$$addr" "$$h"; \
	done; \
	printf '\n  sudo sed -i "/platform.local/d" /etc/hosts   # the on-prem lines point elsewhere\n'; \
	printf '  # then append the lines above\n\n'; \
	printf '%bOr skip the hosts file entirely, which is what I would do:%b\n' '\033[2m' '\033[0m'; \
	printf '  make gcp-ca\n'; \
	for h in $$(yq -r '[.routes[].hostname] | .[] | select(. != null and . != "")' \
	              gitops/environments/gcp/platform-ingress.yaml); do \
	  printf '  curl -sS --cacert .cache/gcp-platform-ca.crt --resolve %s:443:%s https://%s -o /dev/null -w "%%{http_code}\\n"\n' "$$h" "$$addr" "$$h"; \
	done

.PHONY: gcp-ca
gcp-ca: ## Export the GKE cluster's internal CA so curl can verify the Gateway
# A SECOND, DIFFERENT CA, and the file name says so on purpose.
#
# `make onprem-ca` writes .cache/platform-ca.crt. This writes .cache/gcp-platform-ca.crt, because
# the two clusters each run their own cert-manager and each generated its own self-signed root
# (ADR-0011's design, applied twice). Same chart, same ClusterIssuer name, same wildcard - two
# unrelated keys. Using the wrong file produces a verification error that reads like a broken
# certificate rather than the wrong CA.
	@mkdir -p .cache
	@kubectl --context gcp-platform -n cert-manager get secret platform-ca-tls \
	  -o jsonpath='{.data.ca\.crt}' | base64 -d > .cache/gcp-platform-ca.crt
	@printf 'wrote .cache/gcp-platform-ca.crt\n\n'
	@openssl x509 -in .cache/gcp-platform-ca.crt -noout -subject -enddate | sed 's/^/    /'
	@printf '\nThis is NOT the same CA as .cache/platform-ca.crt. Two clusters, two roots.\n'
	@printf 'A browser pointed at this Gateway will warn, from a public address, and that is the\n'
	@printf 'honest consequence of a private CA rather than a misconfiguration (ADR-0021).\n'

.PHONY: gcp-smoke
gcp-smoke: ## Read back what the GKE cluster actually is (nodes, datapath, metrics, the seam)
# NOT `make smoke` with a different context. Three of that script's assertions cannot hold here -
# three nodes, a node named k8s-cp01, our own metrics-server - and the third must not. The
# divergence is the measurement ADR-0001 asked for, not a gap; the script says which is which.
	@bash scripts/gcp-smoke.sh

.PHONY: etcd-encryption-check
etcd-encryption-check: ## Read etcd directly: are Secrets ciphertext or plaintext?
	@bash scripts/etcd-encryption-check.sh

.PHONY: etcd-reencrypt
etcd-reencrypt: ## Rewrite every Secret so the ones predating encryption get encrypted
# The step everyone skips. Turning encryption on does not reach backwards: a Secret is encrypted
# when it is next WRITTEN, and nothing rewrites them on its own. `kubectl replace` with the same
# content is the rewrite - no value changes, every value gets re-encoded through the new provider.
	@set -eu; \
	if ! kubectl -n kube-system get pod -l component=kube-apiserver \
	     -o jsonpath='{.items[0].spec.containers[0].command}' | grep -q encryption-provider-config; then \
	  printf 'The running API server has no --encryption-provider-config.\n\n'; \
	  printf 'Rewriting every Secret now would re-encode them all as plaintext, which is a lot of\n'; \
	  printf 'churn for no gain. Enable encryption first:\n'; \
	  printf '  make onprem-up TAGS=etcd-encryption\n'; \
	  exit 1; \
	fi; \
	n=$$(kubectl get secrets -A --no-headers 2>/dev/null | wc -l | tr -d ' '); \
	printf 'This rewrites all %s Secrets in every namespace, in place.\n\n' "$$n"; \
	printf 'No VALUE changes - each Secret is replaced with its own content, which is what makes\n'; \
	printf 'the API server re-encode it through the encryption provider. What does change is every\n'; \
	printf 'resourceVersion, so anything watching Secrets sees an update: External Secrets may\n'; \
	printf 'resync and Argo CD may re-read. Pods are NOT restarted - a secretKeyRef env var is\n'; \
	printf 'resolved at pod creation and is unaffected.\n\n'; \
	printf 'continue? [y/N] '; \
	read -r ans; \
	case "$$ans" in [yY]*) ;; *) echo "nothing done."; exit 0 ;; esac; \
	printf '\n'; \
	out=$$(kubectl get secrets -A -o json | kubectl replace -f - 2>&1); \
	done=$$(printf '%s\n' "$$out" | grep -c ' replaced$$' || true); \
	fail=$$(printf '%s\n' "$$out" | grep -vc ' replaced$$' || true); \
	printf '%s\n' "$$out" | tail -4 | sed 's/^/    /'; \
	printf '    ...\n'; \
	printf '    %s of %s replaced' "$$done" "$$n"; \
	if [ "$$fail" -gt 0 ]; then printf ', %s line(s) that were not a replacement:\n' "$$fail"; \
	  printf '%s\n' "$$out" | grep -v ' replaced$$' | head -5 | sed 's/^/      /'; \
	else printf '\n'; fi; \
	printf '\nNow check it, against etcd rather than against this output:\n'; \
	printf '  make etcd-encryption-check\n'
# The count is here because the first version piped the output through `tail -5` and nothing else,
# so a run that replaced seventeen Secrets printed five lines and read as though five had been
# done. A truncated list presented as a result is a small lie, and this target's whole job is to
# touch every Secret in the cluster - "how many" is the only number that matters.
#
# `grep -vc ' replaced$$'` also surfaces the case that matters more: a Secret kubectl REFUSED to
# replace. Those lines were previously indistinguishable from the successes they were buried
# among, and a Secret that was not rewritten stays plaintext in etcd for good.

.PHONY: secrets-audit
secrets-audit: ## Is any LIVE credential findable in this repo's working tree or history?
# The roadmap's bar is "git grep finds no credential". That is a claim about this repository, so
# the repository answers it - against the values that are actually live in the cluster and in
# .cache/vault-init.json, rather than against a list someone thought to check.
	@bash scripts/secrets-audit.sh

.PHONY: netpol-check
netpol-check: ## Prove the tenant network policy denies something (two pods, one label apart)
	@bash scripts/netpol-check.sh

.PHONY: shopverse-check
shopverse-check: ## Module 06's gate - checkout end to end, then restart MongoDB and re-read the order
	@bash scripts/shopverse-check.sh

.PHONY: shopverse-admin
shopverse-admin: ## Show ShopVerse's admin login (from the Secret, never from Git)
	@set -eu; \
	ns=$$(yq -r '.spec.destination.namespace' gitops/clusters/onprem/apps/shopverse.yaml); \
	name=$$(yq -r '.secrets.existingSecret' gitops/environments/onprem/shopverse.yaml); \
	printf 'email:    %s\n' "$$(kubectl -n "$$ns" get secret "$$name" -o jsonpath='{.data.admin-email}' | base64 -d)"; \
	printf 'password: %s\n' "$$(kubectl -n "$$ns" get secret "$$name" -o jsonpath='{.data.admin-password}' | base64 -d)"

.PHONY: argocd-password
argocd-password: ## Show the Argo CD admin password (CTX= to pick a cluster)
# Deliberately prints NOTHING but the password, so `$(make -s argocd-password)` stays usable.
# Every cluster's Argo CD generates its own, so this is a different string per context - which
# is why argocd-ui below prints the context next to it.
	@$(KUBECTL) -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: argocd-ui
argocd-ui: ## Port-forward the Argo CD UI to http://localhost:8080 (CTX= to pick a cluster)
	@printf 'cluster:  \033[36m%s\033[0m\n' "$(CTX_SHOW)"
	@echo "user:     admin"
	@echo "password: $$($(MAKE) -s argocd-password CTX=$(CTX))"
	@echo "open      http://localhost:8080"
	@$(KUBECTL) -n argocd port-forward svc/argocd-server 8080:80

.PHONY: gitops-status
gitops-status: ## What Argo CD thinks the cluster should look like, and whether it agrees
# A single-source Application records .status.sync.revision; a MULTI-source one records
# .status.sync.revisions, plural, one per source - and leaves the singular empty. The first
# version of this target read only the singular, so metrics-server, the first multi-source
# component in the repo, showed its revision as <none>. jq coalesces the two.
# The jq program is ONE line on purpose. Make consumes the backslash in a line continuation
# and passes the rest through, so a multi-line quoted script arrives at jq with literal
# backslashes in it and fails to compile - which is what the first version of this did.
	@printf 'cluster: \033[36m%s\033[0m\n' "$(CTX_SHOW)"
	@$(KUBECTL) -n argocd get applications -o json 2>/dev/null \
	  | jq -r '["APP","PROJECT","SYNC","HEALTH","REVISION"], (.items[] | [.metadata.name, .spec.project, (.status.sync.status // "-"), (.status.health.status // "-"), ((.status.sync.revision // (.status.sync.revisions // ["-"])[0])[0:12])]) | @tsv' \
	  | { column -t 2>/dev/null || cat; } \
	  || { echo "Argo CD is not installed on this cluster - run: make onprem-argocd, or make gcp-argocd"; exit 1; }

.PHONY: gitops-refresh
gitops-refresh: ## Make Argo CD re-read Git NOW instead of waiting for its poll
	@# Argo CD reconciles on a timer - 180s by default - so for the first minutes after a push
	@# `gitops-status` shows every Application Synced and Healthy at the PREVIOUS revision. That
	@# is not drift and not a failure, but it reads exactly like the new thing is broken: the
	@# route you just added returns 404 because it does not exist yet.
	@#
	@# This annotation is what the UI's Refresh button sets. It asks for a re-read of Git; it
	@# does not force a sync, so an Application with automated sync off still only reports.
	@printf 'cluster: \033[36m%s\033[0m\n' "$(CTX_SHOW)"
	@for app in $$($(KUBECTL) -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'); do 	  $(KUBECTL) -n argocd annotate application "$$app" 	    argocd.argoproj.io/refresh=normal --overwrite >/dev/null; 	done
	@printf 'asked Argo CD to re-read Git for every Application. Give it a few seconds, then:\n'
	@printf '  make gitops-status\n\n'
	@printf 'Compare the REVISION column against:  git rev-parse --short=12 HEAD\n'
	@printf 'A revision behind HEAD after this means the repo-server cannot reach Git, which is\n'
	@printf 'a different problem from a slow poll and shows up in the Application conditions.\n'

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

.PHONY: gitops-check-pins
gitops-check-pins: ## Is any wrapper chart's pinned version behind what the repo offers?
# Written because three pins in a row were guessed wrong from memory and corrected only when a
# human ran `helm search`. A pin should be a decision, and a decision needs the current value in
# front of it - so the repository answers "is this behind?" rather than someone remembering to
# ask.
	@bash scripts/gitops-check-pins.sh

.PHONY: gitops-limits
gitops-limits: ## What resource limits every container ACTUALLY got (catches a wrong values path)
# Helm ignores a value path that does not exist, in silence. So `resources:` set under the wrong
# key produces a correct-looking values file and an unbounded container, with nothing anywhere
# reporting it. This renders every chart and reads the answer off the containers.
	@bash scripts/gitops-limits.sh $(or $(ENV),onprem)

.PHONY: gitops-render
gitops-render: ## Render a wrapper chart as Argo CD will (CHART=cert-manager [ENV=onprem])
	@test -n "$(CHART)" || { echo "usage: make gitops-render CHART=<name> [ENV=onprem]"; \
	  echo "charts: $$(ls -1 gitops/charts | tr '\n' ' ')"; exit 1; }
	@bash scripts/gitops-render.sh $(CHART) $(or $(ENV),onprem)

# ---------------------------------------------------------------- platform

.PHONY: smoke
smoke: ## Run the cluster smoke test against the current kube context
	@bash scripts/smoke-test.sh

.PHONY: lint
lint: ## Everything checkable without a cluster - run this before pushing
	@bash scripts/lint.sh
