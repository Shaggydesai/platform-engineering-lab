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
  ok "\`kubectl top nodes\` returns data for $(printf '%s' "$top" | wc -l | tr -d ' ') node(s)"
  note 'and nothing in this repository installed it - GKE provides it (ADR-0020)'
else
  # Not a hard failure on a cluster minutes old: the managed metrics-server needs a scrape or
  # two before it has anything to report, and "no metrics yet" reads identically to "broken".
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
