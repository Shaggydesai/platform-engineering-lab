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
warn() { printf "    %s[warn]%s %s\n" "$c_warn" "$c_off" "$*"; unknowns=$((unknowns + 1)); }
note() { printf '           %s%s%s\n' "$c_dim" "$*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

fails=0

# THREE OUTCOMES, NOT TWO, and the omission of this counter was a real bug rather than a
# refinement. This script printed "every check passed" on a run where the tenant namespace did not
# exist, because `warn` incremented nothing - so a warning was indistinguishable from a pass in
# the one line a human actually reads.
#
# The lesson was already written down twice in this repository before this script was created:
# `gcp-guardrails-verify.sh` exits 2 for "I could not look" and says at length why that is neither
# a pass nor a failure, and the parking-lot entry for `make eso-check` records the same fix in the
# same words - "three outcomes instead of two: yes, no, and NOT KNOWN". Then this was written with
# two. Applying a lesson in the place it was learned and not in the next place is the shape to
# watch for; it is the fourth time here.
#
#   fails     something is DEPLOYED AND WRONG        exit 1
#   unknowns  something could not be ESTABLISHED     exit 2   (not a pass)
#   neither                                          exit 0
unknowns=0

command -v jq >/dev/null || die "jq not installed - run: make tools"
kubectl config get-contexts -o name | grep -qx "$CTX" \
  || die "no kubectl context named $CTX

  make gcp-up           the cluster
  make gcp-kubeconfig   creates and names the context"

K="kubectl --context $CTX"

# The CA that verifies this Gateway, and it is the GCP one on purpose.
#
# `make onprem-ca` writes .cache/platform-ca.crt; this cluster's cert-manager generated its own
# unrelated self-signed root, exported by `make gcp-ca`. Pointing curl at the wrong one produces a
# verification error that reads like a broken certificate rather than the wrong CA.
CA_FILE=.cache/gcp-platform-ca.crt

# AND THIS SCRIPT FETCHES IT RATHER THAN ASKING FOR IT.
#
# The first version warned "no CA file, run make gcp-ca" - a check that ends in a round trip to a
# human for data it can read itself, which is a shape already named in this project's parking lot.
# It has a kubeconfig and the Secret is right there. So it exports the CA if the file is absent
# or empty, and only gives up - with a reading of WHY - if cert-manager has not issued the root.
probe_ca() {
  [[ -s "$CA_FILE" ]] && return 0
  mkdir -p "$(dirname "$CA_FILE")"
  $K -n cert-manager get secret platform-ca-tls \
     -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "$CA_FILE" 2>/dev/null || true
  [[ -s "$CA_FILE" ]] || { rm -f "$CA_FILE"; return 1; }
  return 0
}

project=$(jq -r '.project_id' "$CFG")
zone=$(jq -r '.zone' "$CFG")
want_nodes=$(jq -r '.nodes.count' "$CFG")
want_machine=$(jq -r '.nodes.machine_type' "$CFG")
want_pool=$(jq -r '.nodes.pool_name' "$CFG")

printf '%sWhat the GKE cluster actually is%s\n' "$c_step" "$c_off"
printf '  context %s   project %s   zone %s\n' "$CTX" "$project" "$zone"

# ---------------------------------------------------------------- 1. the nodes
step "the nodes, and the one that is not there"
# STDERR SEPARATELY FROM STDOUT, and the reason is a message this script actually printed:
#
#     [fail] cannot reach the cluster: {
#
# `2>&1` merged them and `head -1` took the first line - and `kubectl -o json` had already emitted
# an opening brace to stdout before failing, so the real error was discarded and replaced with a
# brace. The same mistake `cost-check` was fixed for: stdout is the ANSWER, stderr is WHY THERE IS
# NO ANSWER, and merging them loses whichever matters.
k_err=$(mktemp); trap 'rm -f "$k_err"' EXIT
if ! nodes_json=$($K get nodes -o json 2>"$k_err"); then
  err=$(cat "$k_err")
  bad "cannot reach the cluster"
  printf '%s\n' "$err" | head -3 | sed 's/^/           /'

  # A STALE CONTEXT IS THE LIKELY CAUSE AND IS ENTIRELY PREDICTABLE, so name it rather than
  # leaving a certificate error to be interpreted.
  #
  # `make gcp-down` followed by `make gcp-up` destroys and recreates the cluster. The kubectl
  # context SURVIVES both, under the same name, often pointing at the same endpoint address - and
  # holding the OLD cluster's CA. kubectl then connects to the right address and rejects the
  # certificate, which reads like a network or permissions problem.
  #
  # This is the same lesson as the tenant namespace one in a different shape: a context EXISTING
  # is not a context that WORKS. Both this script and the argocd role used to check only the
  # first.
  case "$err" in
    *x509*|*"certificate"*|*"Unauthorized"*|*"credential"*|*"no such host"*|*"refused"*|*"i/o timeout"*)
      note ''
      note 'THAT LOOKS LIKE A STALE CONTEXT, which is what a destroy-and-recreate always leaves:'
      note 'the context keeps its name and its old CA while the cluster behind it is new.'
      note '  make gcp-kubeconfig'
      ;;
    *)
      note ''
      note 'If the cluster was just recreated, the context still holds the previous CA:'
      note '  make gcp-kubeconfig'
      ;;
  esac
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
note 'than a probe. `make netpol-check` is the probe, and it has no GCP counterpart yet.'
note ''
note 'IT IS NO LONGER BLOCKED, which is a change from when this note was written: there IS a'
note 'tenant on this cluster now, so there is something to write policies about. What is still'
note 'missing is the one rule that cannot be written once for three substrates - "allow the'
note 'ingress layer in" - because the source is Cilium Envoy presenting as reserved:host'
note 'on-prem and a Google-owned range here. Porting netpol-check is now a real task rather'
note 'than a dependency.'

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
      # Same distinction as the tenant below: absent-because-not-deployed is a warning,
      # absent-while-its-Application-reports-Synced is a failure. A Synced Application whose
      # object is not in the cluster is the exact shape ADR-0016 named for the Ingress object.
      eso_app=$($K -n argocd get application external-secrets \
                -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
      if [[ "$eso_app" == "Synced" ]]; then
        bad 'the external-secrets Application is Synced but there is no ClusterSecretStore'
        note 'Synced means Argo CD believes the cluster matches Git. If the store is not here,'
        note 'either secretStore.enabled is false in the overlay, or the chart rendered nothing'
        note 'for it - check with:  make gitops-render CHART=external-secrets ENV=gcp'
      else
        warn "no ClusterSecretStore/vault-backend yet (Application: ${eso_app:-absent})"
        note 'it renders in sync wave 1, after the CRDs, so give it a moment'
      fi
      ;;
  esac
fi

# ---------------------------------------------------------------- 5b. the Gateway
step "ingress: is there a Gateway, and did the cloud give it an address?"
if ! $K -n platform-ingress get gateway platform >/dev/null 2>&1; then
  ing_app=$($K -n argocd get application platform-ingress \
            -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  if [[ "$ing_app" == "Synced" ]]; then
    bad 'the platform-ingress Application is Synced but there is no Gateway'
    note 'Synced means Argo CD believes the cluster matches Git. Check the render:'
    note '  make gitops-render CHART=platform-ingress ENV=gcp'
  else
    warn "no Gateway yet (platform-ingress Application: ${ing_app:-absent})"
    note 'it is in sync wave 1, after the Certificate - and a global load balancer takes'
    note 'MINUTES to provision, which is longer than anything Cilium does on-prem'
  fi
else
  # WAIT FOR IT, because this is the slowest thing on this substrate and it had no wait at all.
  #
  # THE BUG THIS FIXES, and the first diagnosis of it was wrong, which is the part worth keeping.
  #
  # The check read `Programmed` and reported `<absent>` as a failure. I concluded the condition
  # name was the problem - that GKE wrote `Ready` instead - and committed that explanation. Three
  # minutes later the same Gateway reported, in full:
  #
  #     Scheduled=True  Accepted=True  Programmed=True  Ready=True
  #     networking.gke.io/GatewayHealthy=True
  #
  # The name was right. THE GATEWAY WAS STILL PROVISIONING. A global Application Load Balancer
  # takes minutes - a fact written in this script's own notes, two sections above, by me - and the
  # check then read a transient state once and called it a verdict.
  #
  # That is the Module 07 lesson verbatim, from the parking-lot entry about the External Secrets
  # store read during its exponential backoff: "a retrying operator and a broken one look
  # identical in a single read", which cost an hour. Every other slow thing here has a wait - the
  # root Application retries 30 times, eso-check waits 150s - and the slowest one had none.
  #
  # So it waits. And the SECOND diagnosis being right does not retire the first lesson: "absent is
  # not False" still holds below, because an implementation genuinely may not write a condition
  # the spec defines, and a false negative sends someone to debug a working load balancer.
  # AND IT WAITS FOR THE RIGHT SIGNAL, which the first version of this wait did not.
  #
  # THIRD CORRECTION, and this one is measured rather than reasoned. The wait below originally
  # polled for the ADDRESS, on the argument that "with addressFrom: provider the cloud is the only
  # possible source of an address, and it does not allocate one for a Gateway it has not
  # programmed". That argument is FALSE, and the run that shipped it says so in its own output:
  #
  #     [fail] Gateway is Programmed=<absent>
  #     [ ok ] the cloud allocated 34.36.43.255
  #
  # The address was there. Programmed was not. GKE reserves the IP early and sets Programmed when
  # the URL map, target proxy and forwarding rule are actually in place, so an address is the
  # FIRST step of provisioning, not the last - which makes it the one signal guaranteed to appear
  # before the thing being waited for. Waiting on it is waiting on nothing.
  #
  # So the wait polls the conditions and stops when Programmed or Ready reports True.
  #
  # IT DOES NOT FAST-FAIL on a False condition, deliberately, and that is the expensive-looking
  # choice. GKE publishes Programmed=False with reason Pending while it works, so a fast-fail on
  # "any condition False" would fail a Gateway that is merely provisioning - the exact trap the
  # External Secrets note describes, re-laid one layer down. The reasons that mean "a human must
  # act" could be listed instead, but I would be guessing the strings, and a guessed list that is
  # wrong fails healthy clusters silently. A broken Gateway therefore costs the full deadline
  # once; a healthy one costs one API call.
  gw_wait=300
  gw_json=''
  gw_conds=''
  gw_bad=''
  for _ in $(seq 1 $((gw_wait / 10))); do
    gw_json=$($K -n platform-ingress get gateway platform -o json 2>/dev/null || true)
    if [[ -n "$gw_json" ]]; then
      gw_conds=$(printf '%s' "$gw_json" \
                 | jq -r '[.status.conditions[]? | "\(.type)=\(.status)"] | join(" ")')
      case "$gw_conds" in *Programmed=True*|*Ready=True*) break ;; esac
    fi
    sleep 10
  done
  gw_addr=$(printf '%s' "$gw_json" | jq -r '.status.addresses[0].value // ""' 2>/dev/null || true)
  gw_class=$(printf '%s' "$gw_json" | jq -r '.spec.gatewayClassName // ""' 2>/dev/null || true)
  gw_bad=$(printf '%s' "$gw_json" \
           | jq -r '[.status.conditions[]? | select(.status != "True")
                     | "\(.type)=\(.status) \(.reason // ""): \(.message // "")"] | join("; ")' \
           2>/dev/null || true)

  # TWO INDEPENDENT SIGNALS, and a verdict only where they agree or something is explicitly False.
  #
  # A condition explicitly False after the deadline is a finding. A condition merely MISSING is
  # not - that lesson survives the correction above, because an implementation may genuinely never
  # write a condition the spec defines, and failing on its absence sends someone to debug a
  # working load balancer. Missing-but-addressed is therefore a warning, not a failure.

  case "$gw_conds" in
    *Programmed=True*)
      ok "Gateway is Programmed   class $gw_class"
      note 'Accepted and Programmed are different claims: the first means a controller read the'
      note 'object, the second means a load balancer exists. Only the second serves traffic.' ;;
    *Ready=True*)
      ok "Gateway reports Ready   class $gw_class"
      note 'this implementation writes Ready, the older spelling, rather than Gateway API v1'"'"'s'
      note 'Programmed - which is why neither name alone is asserted here.' ;;
    *)
      if [[ -n "$gw_bad" ]]; then
        bad "the Gateway is not programmed after ${gw_wait}s: $gw_bad"
        note 'that is a condition the controller set to False on purpose, with a reason - so it'
        note 'is a state it intends to stay in, not provisioning. Start from the message above.'
      elif [[ -n "$gw_addr" ]]; then
        warn "neither Programmed nor Ready is True after ${gw_wait}s, and no condition is False"
        note 'an address exists, so something was provisioned. ABSENT IS NOT FALSE: this is a'
        note 'warning rather than a failure because an implementation may never write either'
        note 'condition, and failing on that sends someone to debug a working load balancer.'
        note "  kubectl --context $CTX -n platform-ingress describe gateway platform"
      else
        bad "no address and no Programmed/Ready condition after ${gw_wait}s"
        note 'conditions reported: '"${gw_conds:-none}"
        note "  kubectl --context $CTX -n platform-ingress describe gateway platform"
      fi ;;
  esac

  if [[ -n "$gw_addr" ]]; then
    ok "the cloud allocated $gw_addr"
    note 'EPHEMERAL: a different one next session. On-prem this is a pinned configuration choice'
    note '(ADR-0013); here it is an allocation, and reserving one bills while unattached.'
    note 'It is also NOT evidence that the load balancer works - GKE reserves the IP first and'
    note 'programs the data path afterwards, which is what the wait above exists to survive.'
    note '  make gcp-address    the current one, and the curl lines to match'
  fi

  # THE ADDRESS IS ALSO THE BILL, so say the number rather than leaving it to be remembered.
  # A forwarding rule is the billed object; the rest of the load balancer is free.
  if frules=$(gcloud compute forwarding-rules list --project="$project" \
                --format='value(name)' 2>/dev/null); then
    n_fr=$(printf '%s\n' "$frules" | grep -c . || true)
    if (( n_fr > 0 )); then
      note ''
      note "$n_fr Google forwarding rule(s) exist, and they are BILLED HOURLY while they do."
      note 'ADR-0003 forbids LEAVING one running, not creating one - which is why make gcp-down'
      note 'deletes this Application and waits for them to go BEFORE destroying the cluster.'
      note 'Terraform never created them and has no record of them (ADR-0021).'
    fi
  fi

  # DID THE GATEWAY ACCEPT THE ROUTES, or do the objects merely exist?
  #
  # The previous version of this check counted HTTPRoute OBJECTS and printed "2 HTTPRoute(s)
  # attached" - a word it had not checked. On 2026-11-02 that line was green while BOTH hostnames
  # returned 404 through the load balancer.
  #
  # 404 and 502 say different things here, and the difference is most of the diagnosis. A 502
  # means Google matched a rule and the backend behind it failed. A 404 means NO RULE MATCHED:
  # the request reached the load balancer and was answered by its default backend, so the route
  # never became a URL-map rule at all. Counting objects cannot tell those apart; it reports the
  # same "2" in both cases, and in the case where the Gateway is missing entirely it reports 2 as
  # well, because HTTPRoutes are perfectly happy to exist with no parent.
  #
  # The Gateway publishes the number that answers it - .status.listeners[].attachedRoutes - and
  # the controller computes that, not us. Each route also publishes, per parent, whether it was
  # Accepted and whether its backendRefs ResolvedRefs. Those are the two questions.
  #
  # This is the third place in this project where a check counted what exists instead of asking
  # whether it took effect, after the Vault unseal count and the Argo CD context list.
  #
  # attachedRoutes is deliberately NOT compared against the object count: a route attached to both
  # the HTTP and HTTPS listener is counted by each, so the sum is not the number of routes and an
  # equality test would fail on a correct cluster. What is asserted is that some listener has a
  # non-zero count, and that no route reports a condition that is False.
  # THE GATEWAY IS RE-READ HERE, and that is not a contradiction of the note above about not
  # re-reading the address. "Is it programmed" and "did routes attach" are different questions
  # with different answers at the same instant: the wait above returns the moment Programmed
  # first goes True, and at that instant attachedRoutes is routinely still 0 - the routes attach
  # seconds to a minute later. Reading them out of that snapshot would report 0 on a cluster
  # that attached them correctly, which is the false negative from the top of this section with
  # a different field in it.
  routes=$($K get httproute -A --no-headers 2>/dev/null | grep -c . || true)
  attached_max=0
  listeners=''
  for _ in $(seq 1 9); do
    gw_now=$($K -n platform-ingress get gateway platform -o json 2>/dev/null || true)
    [[ -z "$gw_now" ]] && break
    attached_max=$(printf '%s' "$gw_now" \
                   | jq -r '[.status.listeners[]?.attachedRoutes // 0] | max // 0' 2>/dev/null || echo 0)
    # The port comes from .spec.listeners, joined by name. .status.listeners carries name,
    # supportedKinds, attachedRoutes and conditions - and NOT port, which the first version of
    # this line read anyway and printed as "port null" on a correct cluster. Small, and the same
    # error as everything else in this section: reading a field without checking it is there.
    listeners=$(printf '%s' "$gw_now" \
                | jq -r '(reduce (.spec.listeners[]? | {(.name): .port}) as $p ({}; . + $p)) as $ports
                         | .status.listeners[]?
                         | "    \(.name)  port \($ports[.name] // "?")  attachedRoutes=\(.attachedRoutes // 0)"' \
                2>/dev/null || true)
    (( attached_max > 0 )) && break
    (( routes == 0 )) && break
    sleep 10
  done
  route_bad=$($K get httproute -A -o json 2>/dev/null | jq -r '
                .items[]
                | .metadata.namespace as $ns | .metadata.name as $n
                | (.status.parents // []) as $ps
                | if ($ps | length) == 0
                  then "\($ns)/\($n): no parent status at all - no controller ever claimed it"
                  else ($ps[]
                        | select([(.conditions // [])[] | select(.status != "True")] | length > 0)
                        | "\($ns)/\($n) -> \(.parentRef.name): "
                          + ([(.conditions // [])[] | select(.status != "True")
                              | "\(.type)=\(.status) \(.reason // "")"] | join(", ")))
                  end' 2>/dev/null || true)

  if (( routes == 0 )); then
    warn 'no HTTPRoutes exist'
    note 'they render from gitops/charts/platform-ingress/templates/httproutes.yaml, in the same'
    note 'chart as the Gateway - so if the Gateway is there and these are not, a values guard is'
    note 'turning them off. Check routes.* in gitops/environments/gcp/platform-ingress.yaml.'
  elif [[ -n "$route_bad" ]]; then
    bad "an HTTPRoute was not accepted by the Gateway:"
    printf '%s\n' "$route_bad" | sed 's/^/           /'
    note ''
    note 'THIS IS WHAT A 404 THROUGH THE LOAD BALANCER LOOKS LIKE FROM THE CLUSTER SIDE. The'
    note 'object exists, the controller read it and refused it, and nothing was written into'
    note 'the URL map - so Google answers with its default backend.'
    note 'The usual causes, in the order worth checking:'
    note '  NotAllowedByListeners  the listener allowedRoutes does not permit the route namespace'
    note '                         - these routes live in argocd and shopverse-prod, the Gateway'
    note '                           in platform-ingress, so every attachment here is cross-namespace'
    note '  NoMatchingParent       parentRef name/namespace/sectionName does not name this Gateway'
    note '  NoMatchingListenerHostname  the route hostname is outside the listener hostname'
    note '  BackendNotFound        ResolvedRefs - the Service named does not exist in that namespace'
  elif (( attached_max == 0 )); then
    bad "every route reports accepted, and no listener has a single attached route"
    note 'the routes are satisfied and the Gateway disagrees, which is the one combination that'
    note 'cannot be read off either object alone. attachedRoutes is the controller'"'"'s own count,'
    note 'so this is the controller saying it wrote nothing into the load balancer.'
    note "  kubectl --context $CTX -n platform-ingress get gateway platform -o yaml"
  else
    ok "routes are attached to the listeners, by the Gateway's own count"
    printf '%s\n' "$listeners"
    note ''
    note 'attachedRoutes is computed by the controller. A route object existing proves only that'
    note 'kubectl accepted a file; this number is the Gateway agreeing to serve it.'
    note ''
    note 'A 404 through the load balancer WITH this green is a different problem: Google programs'
    note 'the URL map after the Gateway reports, and propagation runs minutes behind. Re-curl'
    note 'before debugging. A 502 here is the backend, not the routing.'
  fi

  if (( routes > 0 )); then
    printf '\n'
    $K get httproute -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,HOSTS:.spec.hostnames' \
      --no-headers 2>/dev/null | sed 's/^/    /'
    note ''
    note 'Those objects are IDENTICAL to the on-prem ones - same namespace, same backend, same'
    note 'port, attached to a Gateway with a different implementation underneath. Nothing in'
    note 'gitops/charts/platform-ingress/templates/httproutes.yaml is substrate-aware.'
  fi

  # AND NOW ASK THE LOAD BALANCER, which is the only check in this section that is not inference.
  #
  # Everything above reads Kubernetes objects: a Gateway that says it is programmed, listeners
  # that say routes are attached, routes that say they were accepted. On 2026-11-02 every one of
  # those was green and both hostnames returned 404. That is the whole recurring failure of this
  # project in one section - a check that confirms a request was recorded rather than that it took
  # effect - so the section now ends by sending a packet.
  #
  # It retries, because Google programs the URL map AFTER the Gateway reports Programmed and
  # propagation runs minutes behind. A single 404 here is not a verdict either.
  #
  # ONE DEADLINE SHARED BY ALL HOSTNAMES, not a fresh one per hostname. Per-host retries would
  # multiply: two broken names at 120s each is four minutes, on top of the Gateway wait, and the
  # second name is not waiting for anything the first did not already wait through. What is being
  # waited on is ONE url map propagating, so there is one clock.
  if [[ -z "$gw_addr" ]]; then
    : # nothing to curl at; the missing address was already reported above
  elif ! command -v curl >/dev/null 2>&1; then
    warn 'curl is not installed, so nothing here sent a packet through the load balancer'
  elif ! probe_ca; then
    warn "could not obtain the cluster CA, so TLS to the Gateway cannot be verified"
    note 'the Gateway presents a certificate from this cluster'"'"'s own self-signed root, which no'
    note 'system trust store knows, and cert-manager'"'"'s platform-ca-tls Secret is where that root'
    note 'lives. If that Secret is missing, the Certificate never issued and the Gateway has no'
    note 'usable certificate either - which is a finding about cert-manager, not about curl.'
    note "  kubectl --context $CTX -n cert-manager get certificate,secret | grep platform-ca"
  else
    hosts=$($K get httproute -A -o json 2>/dev/null \
            | jq -r '.items[].spec.hostnames[]?' 2>/dev/null | sort -u || true)
    if [[ -z "$hosts" ]]; then
      warn 'no route hostnames to probe'
    else
      probe_deadline=$((SECONDS + 150))
      while read -r host; do
        [[ -z "$host" ]] && continue
        code=''
        while :; do
          code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
                 --cacert "$CA_FILE" --resolve "$host:443:$gw_addr" \
                 "https://$host/" 2>/dev/null || true)
          # Break on a definite answer. A 404, a 5xx and a dead connection are all retried: the
          # first is propagation, the second can be a NEG whose health check has not passed yet,
          # and the third is the load balancer not yet answering on the address it was given.
          case "$code" in 2??|3??|401|403) break ;; esac
          (( SECONDS >= probe_deadline )) && break
          sleep 10
        done
        case "$code" in
          2??|3??|401|403)
            ok "https://$host/ answered $code through the load balancer" ;;
          404)
            bad "https://$host/ still answers 404 after the propagation window"
            note 'TLS completed, so the listener and its certificate are fine - the 404 came from'
            note 'Google, not from an application. It means the URL map has no host rule matching'
            note 'this name. With the route checks above green, the remaining suspect is the URL'
            note 'map itself, so look at what Google actually programmed:'
            note "  gcloud compute url-maps list --project=$project"
            note "  gcloud compute url-maps describe <name> --project=$project" ;;
          50?)
            bad "https://$host/ answered $code - the load balancer matched a rule and the backend did not serve"
            note 'this is the OPPOSITE finding from a 404 and much better news: the routing works.'
            note 'A 502 here is usually the health check failing on the backend NEG, which GKE'
            note 'derives from the Service - so the Service, its ports and its readiness probe:'
            note "  kubectl --context $CTX get events -A --field-selector type=Warning | tail" ;;
          000|'')
            bad "https://$host/ did not complete a connection"
            note 'no HTTP status at all, so this is TLS or reachability rather than routing. Run it'
            note 'by hand to see the actual error - `make gcp-address` prints the exact line.' ;;
          *)
            warn "https://$host/ answered $code, which this check has no reading for" ;;
        esac
      done <<< "$hosts"
    fi
  fi
fi

# ---------------------------------------------------------------- 6. the tenant
step "the tenant: did the credentials arrive, and did anything schedule?"
TNS=shopverse-prod
if ! $K get ns "$TNS" >/dev/null 2>&1; then
  # WHETHER A MISSING NAMESPACE IS A WARNING OR A FAILURE DEPENDS ON WHETHER ANYTHING IS TRYING
  # TO CREATE IT, and the first version of this check did not ask.
  #
  # It said "ShopVerse is not deployed on this cluster yet" and warned. On 2026-11-01 that was
  # printed on a cluster where the `shopverse` Application WAS deployed, was reporting
  # OutOfSync/Missing, and had applied nothing - so the one explanatory sentence was false and
  # the verdict read "every check passed".
  #
  # "Not deployed" and "deployed and not working" are different states with different causes and
  # different next steps. Argo CD knows which one it is, so ask it.
  app_state=$($K -n argocd get application shopverse \
              -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
  if [[ -z "$app_state" ]]; then
    warn "no $TNS namespace and no shopverse Application - the tenant is not deployed here"
    note 'it arrives via Argo CD from gitops/clusters/gcp/apps/shopverse.yaml, through the'
    note 'tenants-gcp root Application. If that root is Synced and this is still absent, the'
    note 'file is in Git but the root is not reading the directory it is in.'
  else
    bad "the shopverse Application exists ($app_state) but created no $TNS namespace"
    note 'So it is deployed and NOT WORKING, which is a different problem from not deployed.'
    note 'Argo CD rendered the chart - it has a revision - and applied nothing. Ask it why:'
    note "  kubectl --context $CTX -n argocd get application shopverse -o json \\"
    note "    | jq '{conditions: [.status.conditions[]?], phase: .status.operationState.phase,"
    note "           message: .status.operationState.message}'"
    note ''
    note 'FIRST THING TO RULE OUT, now that the namespace is platform-granted: whether the'
    note 'platform actually granted it. The tenant Application no longer carries'
    note 'CreateNamespace=true, so it depends on tenant-namespaces (sync wave -20) having run:'
    note "  kubectl --context $CTX -n argocd get application tenant-namespaces"
    note ''
    note 'Those are separate root Applications, so no wave orders one against the other - the'
    note 'tenant failing on a missing namespace and retrying is the expected shape, not a bug.'
    note 'If tenant-namespaces is itself failing, the message says so and this is a consequence.'
    note ''
    note 'THE ORIGINAL CAUSE, for the record: this Application used to ask for'
    note 'CreateNamespace=true, and a Namespace is cluster-scoped, which the `tenants` AppProject'
    note 'blacklists by design. It had never failed on-prem only because Module 06 created that'
    note 'namespace by hand before Argo CD needed it (ADR-0016, 2026-11-01).'
  fi
else
  # IS THE NAMESPACE ARGO CD'S, OR DID SOMEBODY MAKE IT BY HAND?
  #
  # A namespace existing is not the same as a namespace being managed, and this is the check that
  # would have caught the on-prem hole five modules earlier. There, `shopverse-prod` was created
  # by `make shopverse-secret` in Module 06 and was never in Git - invisible, because a namespace
  # looks identical whoever made it.
  #
  # Argo CD records ownership in an ANNOTATION rather than a label on this platform, deliberately:
  # argocd-values.yaml sets application.resourceTrackingMethod to annotation because the older
  # label-based default truncates at Kubernetes' 63-character limit and can make two resources
  # look like they belong to the same Application (ADR-0009 Decision 4).
  owner=$($K get ns "$TNS" \
          -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null || true)
  case "$owner" in
    tenant-namespaces:*)
      ok "the namespace is managed by Argo CD ($owner)"
      note 'granted by the platform, not created by the tenant - which is the fix for the sync'
      note 'failure this Application hit on its first run (ADR-0016, 2026-11-01)'
      ;;
    '')
      bad "$TNS exists but carries no Argo CD tracking annotation - nothing in Git owns it"
      note 'a namespace that exists and is unmanaged is the exact hole this check was added for:'
      note 'ADR-0002 Rule 3 says nothing in Layer 3 is installed by hand, and a namespace is'
      note 'invisible once it exists, so the violation went unnoticed on-prem for five modules.'
      note 'Expected owner: the tenant-namespaces Application.'
      ;;
    *)
      warn "the namespace is tracked by $owner, not tenant-namespaces"
      note 'not wrong in itself, but something other than the platform grant owns it now'
      ;;
  esac

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

  # PENDING IS THE SIGNAL ON THIS SUBSTRATE, and this check has already earned its place.
  #
  # The comment here used to read: "Two e2-medium spot nodes is about 3.8 allocatable vCPU and
  # 5.6 GiB across the pair [...] The estimate said it fits; an estimate is not a measurement, and
  # Pending is what a wrong one looks like."
  #
  # It was wrong by 2.05x and this check is what found it. e2-medium is SHARED-CORE: 2 vCPU
  # nominal, ONE guaranteed, and GKE reports 940m allocatable - so the pair had 1880m, not 3860m.
  # Measured: 939m (99%) and 931m (99%) requested, 10m of headroom, six of eight tenant pods
  # Pending. The nodes are e2-standard-2 now (clusters/gcp/cluster.json records the arithmetic).
  #
  # The lesson generalises past this cluster: a nominal vCPU count is not schedulable CPU, and the
  # scheduler does not schedule against burst capacity.
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

    # THE SCHEDULER ALREADY SAYS WHY, so read it rather than making a human run `describe`.
    #
    # The first version of this check printed the list and a guess ("if the Secret above is
    # missing, that is the cause and not capacity"). On its first real run the Secret was fine and
    # the cause was capacity - and establishing that took a round trip to ask for `kubectl
    # describe`. The message was sitting in the pod's PodScheduled condition the whole time.
    #
    # The scheduler writes things like "0/2 nodes are available: 2 Insufficient cpu", which names
    # the resource AND the node count. That is the whole diagnosis in one line.
    note ''
    note 'why, according to the scheduler:'
    $K -n "$TNS" get pods -o json 2>/dev/null \
      | jq -r '.items[]
               | select(.status.phase != "Running" and .status.phase != "Succeeded")
               # `. as $p` is load-bearing. Written without it, as
               #   [ .status.conditions[]... ] | first // ([.status.containerStatuses...] | first)
               # the `//` binds INSIDE the pipe, so the second branch indexes the ARRAY the first
               # branch built rather than the pod - "Cannot index array with string status" - and
               # jq abandons that item. The pods it dropped were exactly the ones whose reason is
               # in containerStatuses rather than in a condition, i.e. "secret not found": the
               # single most diagnostic message, silently missing.
               | . as $p
               | [$p.metadata.name,
                  (([$p.status.conditions[]? | select(.type=="PodScheduled") | .message] | first)
                   // ([$p.status.containerStatuses[]?.state.waiting.message] | first)
                   // "no reason recorded yet")]
               | @tsv' 2>/dev/null \
      | sort -u -k2 \
      | while IFS=$'\t' read -r pn reason; do note "  $pn"; note "      $reason"; done

    # AND THE NUMBERS, because "Insufficient cpu" invites the question immediately.
    #
    # This is the breakdown that settled the e2-medium capacity failure in one command, after a
    # round trip to a human for `kubectl describe` that should not have been needed.
    note ''
    note 'allocatable vs requested, per node:'
    $K get nodes -o json 2>/dev/null \
      | jq -r '.items[] | [.metadata.name, .status.allocatable.cpu, .status.allocatable.memory] | @tsv' \
      | while IFS=$'\t' read -r nn ncpu nmem; do
          req=$($K describe node "$nn" 2>/dev/null \
                | awk '/Allocated resources/,/Events|^$/' | awk '/cpu  *[0-9]/{print $2" cpu, "$4" (pct)"; exit}')
          note "  $nn  allocatable ${ncpu} cpu / ${nmem}   requested ${req:-unknown}"
        done
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
  elif [[ "$pvc_ph" == "Pending" ]]; then
    # PENDING IS USUALLY A CONSEQUENCE HERE, NOT A FAULT, and reporting it as a second failure is
    # what this check did on its first real run: six tenant pods Pending and the PVC Pending were
    # counted as two findings when they were one.
    #
    # GKE's default StorageClass uses volumeBindingMode: WaitForFirstConsumer - the volume is not
    # provisioned until a pod that mounts it is SCHEDULED, so that the disk is created in the zone
    # the pod landed in. A pod that cannot schedule therefore leaves its claim Pending forever,
    # and the claim is downstream of the pod rather than beside it.
    #
    # The on-prem default (local-path) does the same thing for the same reason, which is why this
    # never looked like a separate problem there: the pods always scheduled.
    mongo_phase=$($K -n "$TNS" get pod shopverse-mongodb-0 \
                  -o jsonpath='{.status.phase}' 2>/dev/null || true)
    binding=$($K get storageclass "${pvc_sc:-}" \
              -o jsonpath='{.volumeBindingMode}' 2>/dev/null || true)
    if [[ "$mongo_phase" != "Running" && "$binding" == "WaitForFirstConsumer" ]]; then
      note "MongoDB's volume is Pending, and that is DOWNSTREAM of the pod, not a second fault"
      note "StorageClass ${pvc_sc:-<unnamed>} is WaitForFirstConsumer, so the disk is not created"
      note "until shopverse-mongodb-0 is scheduled - and it is $mongo_phase. Fix the scheduling"
      note 'and the volume binds on its own; nothing is wrong with storage.'
    else
      bad "MongoDB's volume is Pending on StorageClass ${pvc_sc:-<unnamed>}"
      note "binding mode: ${binding:-unknown}, and shopverse-mongodb-0 is ${mongo_phase:-absent}"
      note 'With the pod Running, or an Immediate binding mode, Pending is a provisioning failure:'
      note "  kubectl --context $CTX -n $TNS describe pvc"
    fi
  elif [[ -n "$pvc_ph" ]]; then
    bad "MongoDB's volume is $pvc_ph, which is neither Bound nor Pending"
  elif $K -n "$TNS" get statefulset shopverse-mongodb >/dev/null 2>&1; then
    # The StatefulSet exists, so its volumeClaimTemplate should have produced a PVC. Absent here
    # is a failure, not a "yet" - and the likeliest cause on this substrate is a StorageClass
    # that does not exist, which leaves the PVC itself missing rather than Pending.
    bad 'the MongoDB StatefulSet exists but there is no PVC'
    note 'a volumeClaimTemplate that cannot be satisfied leaves the claim absent, not Pending.'
    note "check the default StorageClass:  kubectl --context $CTX get storageclass"
  else
    warn 'no PVC and no MongoDB StatefulSet - the tenant chart has not applied yet'
  fi

  printf '\n'
  $K -n "$TNS" get pods -o wide --no-headers 2>/dev/null | awk '{print "    " $1, $2, $3, $7}' \
    | { column -t 2>/dev/null || cat; }

  note ''
  note 'WHAT THIS STILL CANNOT CHECK, and it is the larger half: whether the storefront SERVES.'
  note '`make shopverse-check` registers a user, fills a cart, checks out, deletes MongoDB and'
  note 'confirms the order survived.'
  note ''
  note 'IT IS NO LONGER BLOCKED ON A DECISION - this note used to say there was no Gateway and no'
  note 'ingress here, which stopped being true the moment ADR-0021 shipped. The Gateway exists,'
  note 'the hostnames resolve through it, and `make gcp-ca` exports the CA that verifies it. What'
  note 'shopverse-check still hardcodes is the on-prem nodes.json and the on-prem CA path, so'
  note 'porting it is a real task rather than a dependency.'
  note ''
  note 'Meanwhile, against the Gateway:'
  note '  make gcp-address        prints a curl line per hostname, CA and --resolve included'
  note "  kubectl --context $CTX -n $TNS port-forward svc/shopverse-frontend 8081:80"
fi

# ---------------------------------------------------------------- verdict
printf '\n'
if (( fails )); then
  printf '%s%d check(s) failed%s' "$c_err" "$fails" "$c_off"
  (( unknowns )) && printf '%s, and %d could not be established%s' "$c_warn" "$unknowns" "$c_off"
  printf '\n'
  exit 1
fi
if (( unknowns )); then
  # NOT A PASS, and the exit code says so. Nothing is known to be broken, and something could not
  # be looked at - which on this substrate usually means a component has not been deployed yet.
  # Saying "every check passed" here is what this script did on 2026-11-01 with the tenant
  # namespace absent, and the two words a human reads were both wrong.
  printf '%snothing failed, but %d thing(s) could not be established%s\n\n' \
    "$c_warn" "$unknowns" "$c_off"
  printf 'Read the [warn] lines above. The common case is a component that is not deployed yet,\n'
  printf 'which is a different statement from "the platform is healthy" - and the difference is\n'
  printf 'the whole reason this exits 2 rather than 0.\n\n'
  printf 'And still, regardless (ADR-0003 Decision 5):\n'
  printf '  make gcp-down\n'
  printf '  make cost-check\n'
  exit 2
fi
printf '%severy check passed%s\n\n' "$c_ok" "$c_off"
printf 'And the thing to do next, which no check can do for you (ADR-0003 Decision 5):\n'
printf '  make gcp-down\n'
printf '  make cost-check\n'
