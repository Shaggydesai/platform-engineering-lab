#!/usr/bin/env bash
# Does the GKE cluster actually have the properties this repository claims it has?
#
#   make gcp-smoke
#
# The on-prem equivalent is `make smoke`, and this is deliberately NOT that script with a
# different context. Three of its assertions cannot hold here and one of them must not:
#
#   three nodes            there are two. GKE's control plane is not a node and never appears
#                          in `kubectl get nodes` (clusters/gcp/cluster.json).
#   a node named k8s-cp01  node names come from the managed instance group as
#                          gke-<cluster>-<pool>-<hash>-<random> and are not settable.
#   our metrics-server     GKE runs its own, and a second one would fight it for a
#                          cluster-scoped APIService with no error message. This script asserts
#                          we did NOT install one.
#
# So the two smoke tests diverge, and the divergence is the measurement ADR-0001 asked for
# rather than a gap. What they share is the method: read what the cluster HAS, never what a
# manifest asked for.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CFG=clusters/gcp/cluster.json
CTX=gcp-platform

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s[ ok ]%s %s\n' "$c_ok" "$c_off" "$*"; }
bad()  { printf '    %s[fail]%s %s\n' "$c_err" "$c_off" "$*"; fails=$((fails + 1)); }
warn() { printf '    %s[warn]%s %s\n' "$c_warn" "$c_off" "$*"; }
note() { printf '           %s%s%s\n' "$c_dim" "$*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

fails=0

command -v jq >/dev/null || die "jq not installed - run: make tools"
kubectl config get-contexts -o name | grep -qx "$CTX" \
  || die "no kubectl context named $CTX

  make gcp-up           the cluster
  make gcp-kubeconfig   creates and names the context"

K="kubectl --context $CTX"

project=$(jq -r '.project_id' "$CFG")
zone=$(jq -r '.zone' "$CFG")
want_nodes=$(jq -r '.nodes.count' "$CFG")
want_machine=$(jq -r '.nodes.machine_type' "$CFG")
want_pool=$(jq -r '.nodes.pool_name' "$CFG")

printf '%sWhat the GKE cluster actually is%s\n' "$c_step" "$c_off"
printf '  context %s   project %s   zone %s\n' "$CTX" "$project" "$zone"

# ---------------------------------------------------------------- 1. the nodes
step "the nodes, and the one that is not there"
if ! nodes_json=$($K get nodes -o json 2>&1); then
  bad "cannot reach the cluster: $(printf '%s' "$nodes_json" | head -1)"
  note 'everything below depends on this, so the rest is skipped'
  exit 1
fi

total=$(printf '%s' "$nodes_json" | jq '.items | length')
ready=$(printf '%s' "$nodes_json" | jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length')

if [[ "$total" == "$want_nodes" ]]; then
  ok "$total nodes, which is what $CFG asks for"
else
  bad "$total nodes, $CFG says $want_nodes"
fi
if [[ "$ready" == "$total" ]]; then
  ok "all $ready Ready"
else
  bad "$ready of $total Ready"
fi

# THE ASSERTION THAT HAS NO ON-PREM COUNTERPART, and it is the sharpest single difference
# between the substrates. On-prem, `make smoke` checks that exactly one node carries
# node-role.kubernetes.io/control-plane and that it is tainted. Here there must be NONE: the
# control plane exists, serves this very request, and is not a node.
#
# Checked rather than assumed because the consequence is not cosmetic - every playbook, taint,
# DaemonSet toleration and node-count assertion written for on-prem rests on a control-plane
# node being present and schedulable-but-tainted.
cp_nodes=$(printf '%s' "$nodes_json" | jq '[.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != null)] | length')
if [[ "$cp_nodes" == "0" ]]; then
  ok "no control-plane node in the cluster, as expected on a managed substrate"
  note 'the API server answering this request runs on machines Google does not show you'
else
  bad "$cp_nodes node(s) labelled control-plane - that is not supposed to be possible on GKE"
fi

pool_nodes=$(printf '%s' "$nodes_json" | jq -r --arg p "$want_pool" \
  '[.items[] | select(.metadata.labels["cloud.google.com/gke-nodepool"] == $p)] | length')
if [[ "$pool_nodes" == "$want_nodes" ]]; then
  ok "all $pool_nodes in the \`$want_pool\` pool"
else
  bad "$pool_nodes nodes in pool \`$want_pool\`, expected $want_nodes"
fi

machines=$(printf '%s' "$nodes_json" | jq -r '[.items[].metadata.labels["node.kubernetes.io/instance-type"]] | unique | join(", ")')
if [[ "$machines" == "$want_machine" ]]; then
  ok "every node is $machines"
else
  bad "machine types are [$machines], $CFG says $want_machine"
fi

spot=$(printf '%s' "$nodes_json" | jq -r '[.items[] | select(.metadata.labels["cloud.google.com/gke-spot"] == "true")] | length')
if [[ "$(jq -r '.nodes.spot' "$CFG")" == "true" ]]; then
  if [[ "$spot" == "$total" ]]; then
    ok "all $spot nodes are SPOT - the ~60-90% discount is actually applied"
    note 'and they can be reclaimed at any moment, which is the trade (Module 11 uses it)'
  else
    bad "$spot of $total nodes are spot, and $CFG asks for spot"
    note 'a non-spot node costs roughly three times as much and looks identical in kubectl'
  fi
fi

printf '\n'
$K get nodes -L substrate,pool,cloud.google.com/gke-spot 2>/dev/null | sed 's/^/    /'

# ---------------------------------------------------------------- 2. NetworkPolicy enforcement
step "is NetworkPolicy ENFORCED, or merely accepted?"
# The question that cost a cluster-replacing fix the day before this script existed.
#
# A GKE cluster with neither Dataplane V2 nor the legacy Calico addon ACCEPTS NetworkPolicy
# objects and silently ignores them - so `kubectl apply` succeeds, Argo CD reports Synced and
# Healthy, and nothing is enforced. The first cluster built here was exactly that, and its own
# destroy plan said so in two lines nobody would have read as a finding:
#
#     network_policy { enabled = false, provider = "PROVIDER_UNSPECIFIED" }
#
# This asks the control plane what datapath it is running. It is a configuration read rather
# than a traffic probe, which is a real limitation and stated as one below.
if ! dp=$(gcloud container clusters describe platform \
            --zone "$zone" --project "$project" \
            --format='value(networkConfig.datapathProvider)' 2>&1); then
  warn "could not ask the API: $(printf '%s' "$dp" | head -1)"
  note 'UNKNOWN, not a failure - but the one thing to check by hand before trusting a policy'
else
  dp=$(printf '%s' "$dp" | tr -d '[:space:]')
  if [[ "$dp" == "ADVANCED_DATAPATH" ]]; then
    ok "datapath is ADVANCED_DATAPATH - Dataplane V2, which is GKE's managed Cilium"
    note 'so both substrates enforce plain networking.k8s.io policy with the same engine'
  else
    bad "datapath is '${dp:-unset}', NOT ADVANCED_DATAPATH"
    note 'NetworkPolicy objects will be accepted and will enforce NOTHING on this cluster.'
    note 'It cannot be changed in place - setting it forces cluster replacement. terraform/gcp'
    note 'already sets it, so a cluster without it predates that and needs rebuilding.'
  fi
fi
note ''
note 'WHAT THIS DOES NOT PROVE: that a policy actually blocks a packet. It reads the cluster'
note "configuration, which is one step better than reading our own manifest and one step worse"
note 'than a probe. `make netpol-check` is the probe, and it has no GCP counterpart yet because'
note 'there is no tenant on this cluster to write policies about.'

# ---------------------------------------------------------------- 3. metrics, and whose it is
step "metrics work, and we did NOT install the thing that provides them"
if $K get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1; then
  ok 'the metrics.k8s.io APIService is registered'
else
  bad 'no metrics.k8s.io APIService - `kubectl top` and every HPA depend on it'
fi

if top=$($K top nodes --no-headers 2>&1); then
  # `grep -c .`, NOT `printf '%s' "$top" | wc -l`, and the difference is not pedantry.
  #
  # Command substitution strips the trailing newline, so `printf '%s'` emits N lines separated by
  # N-1 newlines and wc counts N-1. The first run of this script against a real two-node cluster
  # therefore printed "returns data for 1 node(s)" - a number that is wrong, that nobody would
  # question, and that reads exactly like a real and known failure mode: the on-prem parking-lot
  # entry about kubelet serving certificates is precisely "metrics-server cannot scrape some
  # nodes". An off-by-one in a shell pipeline presented as a cluster symptom.
  #
  # So the count is now COMPARED rather than printed. A number with nothing to compare it against
  # is the shape this project keeps finding in its own checks - it looks like evidence and
  # carries none, because no value of it would have failed anything.
  metric_nodes=$(printf '%s\n' "$top" | grep -c . || true)
  if [[ "$metric_nodes" == "$total" ]]; then
    ok "\`kubectl top nodes\` returns data for all $metric_nodes node(s)"
    note 'and nothing in this repository installed it - GKE provides it (ADR-0020)'
  else
    # A shortfall rather than a failure, because the honest reading is ambiguous on a young
    # cluster: GKE's metrics-server needs a scrape or two per node, and "not scraped yet" and
    # "cannot be scraped" look identical in one read. Same lesson as the External Secrets store
    # read during its backoff - a transient state read once is not a verdict.
    warn "metrics for $metric_nodes of $total nodes"
    note 'if this persists across two runs a minute apart it is not warm-up, and the question is'
    note 'why that node cannot be scraped - which on-prem was kubelet serving certificates'
  fi
else
  # Not a hard failure on a cluster minutes old, for the same reason.
  warn "\`kubectl top nodes\` has no data yet: $(printf '%s' "$top" | head -1)"
  note 'normal for the first minute or two after the cluster comes up; re-run before worrying'
fi

# THE OTHER HALF, and it is the half that matters. "metrics work" would also be true if we had
# installed our own metrics-server alongside Google's - and that is precisely the broken state
# this checks for, because it has no symptom. Two metrics-servers both register the same
# cluster-scoped APIService, the last writer owns the endpoint, `kubectl top` keeps working, and
# the HPA reads whichever won.
if $K -n argocd get application metrics-server >/dev/null 2>&1; then
  bad 'an Argo CD Application named metrics-server exists on this cluster'
  note 'gitops/environments/gcp/metrics-server.yaml records the decision NOT to have one.'
  note 'Two metrics-servers conflict over a cluster-scoped APIService with no error message.'
else
  ok 'no metrics-server Application here, which is the decision ADR-0020 recorded'
fi

# ---------------------------------------------------------------- 4. Layer 2 and the seam
step "Layer 2: Argo CD, and the seam it was handed"
if ! $K -n argocd get deploy argocd-server >/dev/null 2>&1; then
  warn 'Argo CD is not installed on this cluster yet'
  note 'make gcp-argocd'
else
  chart_app=$(jq -r '.argocd.app_version' clusters/platform.json)
  live=$($K -n argocd get deploy argocd-server \
         -o jsonpath='{.spec.template.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null)
  if [[ "$live" == "$chart_app" ]]; then
    ok "Argo CD $live, which is what clusters/platform.json pins for EVERY substrate"
  elif [[ -z "$live" ]]; then
    warn 'could not read the running Argo CD version from the deployment labels'
  else
    bad "Argo CD $live is running, clusters/platform.json says $chart_app"
    note 'that file is shared with on-prem, so the two clusters are now running different'
    note 'versions of the thing whose job is to make them the same'
  fi

  root=$($K -n argocd get application platform-gcp \
         -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
  if [[ "$root" == "Synced/Healthy" ]]; then
    ok "root Application platform-gcp: $root"
  else
    bad "root Application platform-gcp: ${root:-missing}"
  fi

  printf '\n'
  $K -n argocd get applications -o json 2>/dev/null \
    | jq -r '["APP","PROJECT","SYNC","HEALTH"], (.items[] | [.metadata.name, .spec.project, (.status.sync.status // "-"), (.status.health.status // "-")]) | @tsv' \
    | { column -t 2>/dev/null || cat; } | sed 's/^/    /'

  # The canary is the cheapest end-to-end proof there is: a ConfigMap rendered from the SAME
  # directory the on-prem cluster renders, with no overlay and no substrate-specific anything.
  # If this value is here, the whole Layer 2 chain worked on a second substrate.
  gen=$($K -n platform-canary get cm gitops-canary -o jsonpath='{.data.generation}' 2>/dev/null || true)
  git_gen=$(grep -E '^  generation:' gitops/manifests/gitops-canary/configmap.yaml \
            | head -1 | sed 's/.*"\(.*\)".*/\1/')
  printf '\n'
  if [[ -n "$gen" && "$gen" == "$git_gen" ]]; then
    ok "the canary ConfigMap says generation=$gen, and so does Git"
    note 'rendered from gitops/manifests/gitops-canary - the same directory on-prem renders'
  elif [[ -n "$gen" ]]; then
    bad "the canary says generation=$gen, Git says $git_gen"
    note 'a push that has not reached this cluster, or a sync that is failing. Try:'
    note '  make gitops-refresh CTX=gcp-platform'
  else
    bad 'the canary ConfigMap is not in the cluster'
    note 'Argo CD is installed but the platform directory has not reconciled'
  fi
fi

# ---------------------------------------------------------------- 5. the secret backend
step "secrets: does Workload Identity actually work?"
if ! $K -n external-secrets get deploy >/dev/null 2>&1; then
  warn 'External Secrets is not installed on this cluster yet'
  note 'it arrives via Argo CD from gitops/clusters/gcp/platform/external-secrets.yaml'
else
  # THE ANNOTATION, read off the live ServiceAccount rather than off our overlay.
  #
  # This exists because of a warning in the chart's own values file: Helm SILENTLY IGNORES a
  # value path that does not exist, so `external-secrets.serviceAccount.annotations` either
  # reaches the subchart or vanishes without a word. A wrong path renders a perfectly valid
  # ServiceAccount with no annotation, Workload Identity is simply off, and the failure surfaces
  # as a 403 from the metadata server - which reads like a missing IAM role.
  #
  # `make lint` checks that the overlay names the right account. Only the cluster can say whether
  # the value took effect. That distinction is the whole reason this file exists.
  want_gsa="external-secrets@${project}.iam.gserviceaccount.com"
  got_gsa=$($K -n external-secrets get sa external-secrets \
            -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}' 2>/dev/null || true)
  if [[ "$got_gsa" == "$want_gsa" ]]; then
    ok 'the ServiceAccount carries the gcp-service-account annotation'
    note 'so the overlay value reached the subchart - which Helm would not have said'
  elif [[ -z "$got_gsa" ]]; then
    bad 'the external-secrets ServiceAccount has NO gcp-service-account annotation'
    note 'Workload Identity is off. Helm ignores an unknown values path without a word, so the'
    note 'likely cause is the path in gitops/environments/gcp/external-secrets.yaml, not IAM.'
  else
    bad "the annotation names $got_gsa"
    note "expected $want_gsa"
  fi

  # The store. Ready=True means ESO exchanged a token, reached Secret Manager, and was allowed
  # to read - all four Terraform resources and the annotation above, in one condition.
  store=$($K get clustersecretstore vault-backend \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  case "$store" in
    True)
      ok 'ClusterSecretStore/vault-backend is Ready'
      note 'still called vault-backend on purpose: the name is the contract the tenant writes'
      note 'against, not a description of the backend (ADR-0018)'
      ;;
    False)
      msg=$($K get clustersecretstore vault-backend \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)
      bad "ClusterSecretStore/vault-backend is Ready=False: ${msg:-no message}"
      note 'READ THIS BY TIME before believing it. ESO backs off exponentially (1s, 4s, 8s,'
      note '16s, 32s), so a store checked seconds after the backend was fixed looks broken and'
      note 'is not - that cost an hour in Module 07. Compare lastTransitionTime against when'
      note 'make gcp-secrets-seed ran, then re-check.'
      note 'If it persists:  make gcp-secrets-verify'
      ;;
    *)
      warn 'no ClusterSecretStore/vault-backend yet'
      note 'the Application may still be syncing - it renders in sync wave 1, after the CRDs'
      ;;
  esac
fi

# ---------------------------------------------------------------- 6. the tenant
step "the tenant: did the credentials arrive, and did anything schedule?"
TNS=shopverse-prod
if ! $K get ns "$TNS" >/dev/null 2>&1; then
  warn "no $TNS namespace - ShopVerse is not deployed on this cluster yet"
  note 'it arrives via Argo CD from gitops/clusters/gcp/apps/shopverse.yaml'
else
  # THE SECRET ESO WROTE, which is the end of the whole chain this substrate was built for:
  # Workload Identity -> Secret Manager -> ExternalSecret -> Secret -> secretKeyRef -> pod.
  # Six keys present means every link held.
  want_keys='admin-email admin-password internal-token jwt-secret mongo-password mongo-username'
  got_keys=$($K -n "$TNS" get secret shopverse-secrets -o json 2>/dev/null \
             | jq -r '.data | keys | sort | join(" ")' || true)
  if [[ "$got_keys" == "$(printf '%s\n' $want_keys | sort | paste -sd' ')" ]]; then
    ok 'shopverse-secrets holds exactly the six keys, written by External Secrets'
    note 'so the full chain held: Workload Identity, Secret Manager, ExternalSecret, Secret'
  elif [[ -z "$got_keys" ]]; then
    bad 'no shopverse-secrets - the ExternalSecret has not produced one'
    es=$($K -n "$TNS" get externalsecret shopverse-secrets \
         -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)
    note "ExternalSecret says: ${es:-(no ExternalSecret object at all)}"
    note 'make gcp-secrets-verify  - and check the store above is Ready'
  else
    bad "shopverse-secrets has [$got_keys]"
    note "the chart's ExternalSecret asks for [$want_keys]"
  fi

  # PENDING IS THE SIGNAL ON THIS SUBSTRATE, and it is worth saying why rather than just
  # checking it. Two e2-medium spot nodes is about 3.8 allocatable vCPU and 5.6 GiB across the
  # pair, carrying Argo CD, cert-manager, External Secrets, GKE's own system pods and Dataplane
  # V2's agent - and then eight tenant pods. The estimate said it fits; an estimate is not a
  # measurement, and Pending is what a wrong one looks like.
  #
  # It is also what a MISSING SECRET looks like, which is why this sits under the check above:
  # a pod whose secretKeyRef names a Secret that does not exist stays Pending with
  # CreateContainerConfigError, and that reads like a capacity problem.
  pending=$($K -n "$TNS" get pods --no-headers 2>/dev/null \
            | awk '$3 != "Running" && $3 != "Completed" {print "        " $1 "  " $3}' || true)
  if [[ -z "$pending" ]]; then
    n_pods=$($K -n "$TNS" get pods --no-headers 2>/dev/null | grep -c . || true)
    ok "all $n_pods tenant pods Running"
  else
    bad 'some tenant pods are not Running:'
    printf '%s\n' "$pending"
    note 'if the Secret above is missing, that is the cause and not capacity - a pod whose'
    note 'secretKeyRef names a missing Secret stays Pending and looks like a scheduling problem'
  fi

  # THE STORAGE DIFFERENCE, read back rather than asserted. On-prem this volume is a directory on
  # one worker's disk and a dead node takes the data with it (ADR-0015). Here it should be a
  # network Persistent Disk that detaches and reattaches - which is most of what "cloud native
  # storage" means, and the clearest thing this substrate buys that a laptop cannot.
  pvc_sc=$($K -n "$TNS" get pvc -o jsonpath='{.items[0].spec.storageClassName}' 2>/dev/null || true)
  pvc_ph=$($K -n "$TNS" get pvc -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  if [[ "$pvc_ph" == "Bound" ]]; then
    ok "MongoDB's volume is Bound on StorageClass ${pvc_sc:-<unnamed>}"
    note 'a network Persistent Disk, not a directory on a node: it detaches from a failed node'
    note 'and reattaches elsewhere, which platform-local on-prem cannot do at any price'
    note 'it is also billed while it exists - make gcp-down takes it, make cost-check checks'
  elif [[ -n "$pvc_ph" ]]; then
    bad "MongoDB's volume is $pvc_ph, not Bound"
  else
    warn 'no PVC in the tenant namespace yet'
  fi

  printf '\n'
  $K -n "$TNS" get pods -o wide --no-headers 2>/dev/null | awk '{print "    " $1, $2, $3, $7}' \
    | { column -t 2>/dev/null || cat; }

  note ''
  note 'WHAT THIS CANNOT CHECK, and it is the larger half: whether the storefront SERVES.'
  note '`make shopverse-check` registers a user, fills a cart, checks out, deletes MongoDB and'
  note 'confirms the order survived - over HTTPS through the on-prem Gateway, with the platform'
  note 'CA. There is no Gateway on this cluster and no ingress, on purpose: an Ingress object'
  note 'here WOULD work and would bill a Google load balancer by the hour (ADR-0003). Until that'
  note 'decision is made, the storefront is reached the same way Argo CD is:'
  note "  kubectl --context $CTX -n $TNS port-forward svc/shopverse-frontend 8081:80"
fi

# ---------------------------------------------------------------- verdict
printf '\n'
if (( fails )); then
  printf '%s%d check(s) failed%s\n' "$c_err" "$fails" "$c_off"
  exit 1
fi
printf '%severy check passed%s\n\n' "$c_ok" "$c_off"
printf 'And the thing to do next, which no check can do for you (ADR-0003 Decision 5):\n'
printf '  make gcp-down\n'
printf '  make cost-check\n'
