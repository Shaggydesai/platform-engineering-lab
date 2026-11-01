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
