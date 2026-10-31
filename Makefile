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
KNOWN_VARS := TAGS ARGS CHART ENV STORE_NAME PROBE_NS VAULT_NS VAULT_POD VAULT_KEYS

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

.PHONY: gcp-guardrails
gcp-guardrails: _no-stray-flags ## ADR-0003 gate - the ₹400 budget alert, BEFORE any cloud resource
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
# A single-source Application records .status.sync.revision; a MULTI-source one records
# .status.sync.revisions, plural, one per source - and leaves the singular empty. The first
# version of this target read only the singular, so metrics-server, the first multi-source
# component in the repo, showed its revision as <none>. jq coalesces the two.
# The jq program is ONE line on purpose. Make consumes the backslash in a line continuation
# and passes the rest through, so a multi-line quoted script arrives at jq with literal
# backslashes in it and fails to compile - which is what the first version of this did.
	@kubectl -n argocd get applications -o json 2>/dev/null \
	  | jq -r '["APP","PROJECT","SYNC","HEALTH","REVISION"], (.items[] | [.metadata.name, .spec.project, (.status.sync.status // "-"), (.status.health.status // "-"), ((.status.sync.revision // (.status.sync.revisions // ["-"])[0])[0:12])]) | @tsv' \
	  | { column -t 2>/dev/null || cat; } \
	  || { echo "Argo CD is not installed - run: make onprem-argocd"; exit 1; }

.PHONY: gitops-refresh
gitops-refresh: ## Make Argo CD re-read Git NOW instead of waiting for its poll
	@# Argo CD reconciles on a timer - 180s by default - so for the first minutes after a push
	@# `gitops-status` shows every Application Synced and Healthy at the PREVIOUS revision. That
	@# is not drift and not a failure, but it reads exactly like the new thing is broken: the
	@# route you just added returns 404 because it does not exist yet.
	@#
	@# This annotation is what the UI's Refresh button sets. It asks for a re-read of Git; it
	@# does not force a sync, so an Application with automated sync off still only reports.
	@for app in $$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'); do 	  kubectl -n argocd annotate application "$$app" 	    argocd.argoproj.io/refresh=normal --overwrite >/dev/null; 	done
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
