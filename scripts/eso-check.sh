#!/usr/bin/env bash
# Prove that a value written to Vault reaches a Kubernetes Secret.
#
#   make eso-check
#
# `make vault-bootstrap` ends by logging in as External Secrets and reading a path. That proves
# Vault's side of the arrangement. It proves nothing about ESO itself: whether the operator is
# running, whether the ClusterSecretStore resolves, whether the NetworkPolicy lets it through,
# whether an ExternalSecret produces a Secret with the right bytes in it.
#
# This writes a FRESH random canary to Vault on every run and then asserts that exact value comes
# out of a Secret. Freshness is the whole design: a leftover Secret from a previous run, or one
# created by hand, cannot pass - which is the difference between "a Secret exists" and "the path
# from Vault to that Secret works right now".
#
# The canary is a random hex string with no meaning. It is not a credential and it is not the
# tenant's secret; those arrive in stage 3.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LIB="$REPO_ROOT/scripts/vault-exec.lib.sh"
[[ -r "$LIB" ]] || { echo "missing $LIB - is this a complete checkout?" >&2; exit 1; }
# shellcheck source=scripts/vault-exec.lib.sh
source "$LIB"

STORE_NAME="${STORE_NAME:-vault-backend}"
SELFTEST_PATH=platform/eso-selftest   # must stay in step with vault-bootstrap.sh
OBJ=eso-selftest

# `default`, deliberately. A dedicated namespace would be tidier and would cost a namespace
# creation plus a termination on every run; and using the tenant's namespace would mean a test
# object landing where a real application lives. What matters for the test is that this is NOT
# the operator's own namespace, because a ClusterSecretStore serving its own namespace would not
# exercise the cluster-scoped path that every tenant actually uses.
PROBE_NS="${PROBE_NS:-default}"

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
same() { printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; }
warn() { printf '    %s%s%s\n' "$c_warn" "$*" "$c_off"; }
bad()  { printf '    %s%s%s\n' "$c_err" "$*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

command -v jq >/dev/null || die "jq not installed - run: make tools"

cleanup() {
  kubectl -n "$PROBE_NS" delete externalsecret "$OBJ" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$PROBE_NS" delete secret "$OBJ" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '%sExternal Secrets end-to-end check%s\n\n' "$c_step" "$c_off"

# ---------------------------------------------------------------- 0  preconditions
step 'the operator, the store, and Vault'
vault_require_ready || exit 1
vault_load_root_token || exit 1

store=$(kubectl get clustersecretstore "$STORE_NAME" -o json 2>/dev/null)
[[ -n "$store" ]] || die "no ClusterSecretStore named $STORE_NAME - run: make gitops-refresh"
q() { printf '%s' "$store" | jq -r "$1 // \"\""; }
KV_MOUNT=$(q '.spec.provider.vault.path')
ESO_SA=$(q '.spec.provider.vault.auth.kubernetes.serviceAccountRef.name')
ESO_NS=$(q '.spec.provider.vault.auth.kubernetes.serviceAccountRef.namespace')

# The store's Ready condition is ESO's own verdict on whether it can reach and authenticate to
# Vault. It is READ here and JUDGED further down, after the diagnostics - which is a correction,
# not a style choice.
#
# The first version died right here on a NotReady store, which meant the next step - the one that
# compares the NetworkPolicy's allowed pod label against the controller's real labels, and the
# one that checks whether ESO can even mint its own token - never ran. The most informative
# checks were gated behind the symptom they explain, so the script reported the failure and
# withheld the diagnosis. On the first real run that cost exactly what it sounds like it cost.
ready=$(printf '%s' "$store" | jq -r '.status.conditions[]? | select(.type=="Ready") | .status' | head -1)
rmsg=$(printf '%s' "$store" | jq -r '.status.conditions[]? | select(.type=="Ready") | .message' | head -1)
case "$ready" in
  True) ok "ClusterSecretStore/$STORE_NAME is Ready" ;;
  "")   warn "ClusterSecretStore/$STORE_NAME has no Ready condition yet - the operator may not have looked at it" ;;
  *)    bad "ClusterSecretStore/$STORE_NAME Ready=$ready: $rmsg"
        same 'continuing to the diagnostics below, which exist for exactly this case' ;;
esac

# ---------------------------------------------------------------- 1  the Kubernetes side
step 'the Kubernetes side: can ESO get a token, and can it reach Vault'
# This step exists because of a specific indistinguishable pair: a wrong pod label in the
# NetworkPolicy and a wrong Vault role produce the same symptom - a store that never becomes
# Ready - and the network one is silent, because a dropped packet produces no error (ADR-0017).
#
# The controller is identified by its SERVICE ACCOUNT, not by a label, because the label is the
# thing under test. ESO's webhook and cert-controller run under different service accounts and
# never talk to Vault.
#
# Two of the outcomes here are warnings rather than failures - no policy at all, and no pod using
# the identity - because the probe below still proves the path either way. The flag records which
# happened, so the closing summary does not claim a policy was verified when none exists. A
# summary that over-claims is how a report becomes evidence for something it never checked.
POLICY_VERIFIED=no
FINDINGS=()

# Can ESO obtain the token it presents to Vault at all?
#
# This is a DIFFERENT question from the one `make vault-bootstrap` answers, and the distinction is
# the whole reason this check is here. Bootstrap ends by logging in to Vault with a token minted
# by `kubectl create token`, i.e. as the cluster admin. That proves Vault's role, policy and
# TokenReview path are correct. It proves nothing about whether ESO - a service account with
# ordinary RBAC - can get a token of its own to present.
#
# With a ClusterSecretStore naming a serviceAccountRef, ESO calls the TokenRequest API for that
# service account. No permission, no token, no Vault client - and the store's condition says
# "unable to create client", which names neither RBAC nor Kubernetes.
if kubectl auth can-i create serviceaccounts/token -n "$ESO_NS" \
     --as="system:serviceaccount:$ESO_NS:$ESO_SA" >/dev/null 2>&1; then
  ok "$ESO_NS/$ESO_SA can mint a token for itself (TokenRequest)"
else
  bad "$ESO_NS/$ESO_SA CANNOT create serviceaccounts/token"
  FINDINGS+=("ESO cannot mint its own service account token, so it cannot build a Vault client.
      The store names serviceAccountRef $ESO_NS/$ESO_SA, which requires the TokenRequest API.
      What is actually granted:
        kubectl get clusterrole -o json | jq -r '.items[]
          | select(.rules[]?.resources[]? == \"serviceaccounts/token\") | .metadata.name'")
fi

ctrl=$(kubectl -n "$ESO_NS" get pods -o json 2>/dev/null \
       | jq -r --arg sa "$ESO_SA" '.items[]
           | select(.spec.serviceAccountName == $sa)
           | .metadata.name + " " + (.metadata.labels["app.kubernetes.io/name"] // "<none>")' | head -1)
if [[ -z "$ctrl" ]]; then
  warn "no pod in $ESO_NS runs as serviceaccount $ESO_SA"
  warn 'so nothing is using the identity the store names - the probe below will say what that costs'
else
  ctrl_pod=${ctrl%% *}; ctrl_label=${ctrl##* }
  same "controller $ctrl_pod carries app.kubernetes.io/name=$ctrl_label"
  if ! npol=$(kubectl -n "$VAULT_NS" get networkpolicy vault-api -o json 2>/dev/null); then
    warn 'no NetworkPolicy vault-api in the vault namespace - every pod in the cluster can reach'
    warn 'Vault'"'"'s plaintext API. Enable networkPolicy in gitops/environments/onprem/vault.yaml.'
  else
    permitted=$(printf '%s' "$npol" | jq -r '.spec.ingress[]?.from[]?.podSelector.matchLabels["app.kubernetes.io/name"] // empty')
    if printf '%s\n' "$permitted" | grep -qx "$ctrl_label"; then
      ok "NetworkPolicy vault-api permits app.kubernetes.io/name=$ctrl_label"
      POLICY_VERIFIED=yes
    else
      bad "NetworkPolicy vault-api permits [$(printf '%s' "$permitted" | tr '\n' ' ')] and the controller is $ctrl_label"
      FINDINGS+=("The NetworkPolicy does not permit the controller, so it cannot open a socket to
      Vault - and a dropped packet produces no error, so the only symptom is a store that never
      becomes Ready. Fix the client name in gitops/environments/onprem/vault.yaml:
        networkPolicy.clients[].name: $ctrl_label
      Then commit and: make gitops-refresh. To watch the drops meanwhile:
        kubectl -n kube-system exec ds/cilium -- hubble observe --to-namespace $VAULT_NS --verdict DROPPED --last 20")
    fi
  fi
fi

# ---------------------------------------------------------------- 1b  now judge the store
# The probe below cannot mean anything against a store ESO has rejected, so this is where the run
# stops - AFTER the diagnostics rather than before them.
if [[ "$ready" != "True" ]]; then
  echo
  bad "ClusterSecretStore/$STORE_NAME is not Ready, so the probe would prove nothing."
  if (( ${#FINDINGS[@]} )); then
    printf '\n%s  %d finding(s) above that would cause exactly this:%s\n\n' "$c_err" "${#FINDINGS[@]}" "$c_off"
    for f in "${FINDINGS[@]}"; do printf '    - %s\n\n' "$f"; done
  else
    printf '\n%s  Nothing in the checks above explains it%s, which narrows it usefully: the identity\n' "$c_warn" "$c_off"
    printf '  can mint a token and the network permits the pod, so the remaining candidates are\n'
    printf '  inside Vault or inside the operator.\n\n'
    printf '    make vault-bootstrap     re-runs clean and says what was missing\n'
    printf '    make vault-status        a sealed Vault refuses every request\n\n'
  fi
  die "ESO's own logs name the reason it could not build a client:
  kubectl -n $ESO_NS logs deploy/external-secrets --tail=40
  kubectl get clustersecretstore $STORE_NAME -o jsonpath='{.status}' | jq ."
fi

# ---------------------------------------------------------------- 2  a fresh value, into Vault
step "writing a FRESH canary to $KV_MOUNT/$SELFTEST_PATH"
CANARY="canary-$(openssl rand -hex 12)"
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Written through the root token, which is this script standing in for whatever will write real
# secrets later. The canary is random per run so that a Secret left over from a previous run
# holds a DIFFERENT value and therefore fails the comparison at the end - the one property that
# makes this a test rather than an observation.
vsh 'vault kv put -mount="$1" "$2" canary="$3" written-at="$4" >/dev/null' \
    "$KV_MOUNT" "$SELFTEST_PATH" "$CANARY" "$STAMP" \
  || die "could not write to Vault. Has bootstrap run?  make vault-bootstrap"
ok "wrote canary=${CANARY}  (random, not a credential)"

# Remove any leftovers BEFORE creating the ExternalSecret. Without this, an ExternalSecret that
# already exists is not re-reconciled just because Vault changed - it waits for its
# refreshInterval - so the Secret would still hold the previous run's canary and the comparison
# below would fail for a reason that is not a fault.
cleanup
sleep 2

# ---------------------------------------------------------------- 3  the tenant-shaped object
step "creating ExternalSecret $PROBE_NS/$OBJ"
# This manifest is the point of ADR-0018. Nothing in it names Vault, or a Vault path shape, or
# anything else on-prem: it names a store and a key. The identical object works on GKE and EKS
# against Secret Manager and Secrets Manager, which is the property the whole option was chosen
# for and is being exercised here for the first time.
kubectl apply -f - >/dev/null <<YAML
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: $OBJ
  namespace: $PROBE_NS
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: $STORE_NAME
    kind: ClusterSecretStore
  target:
    name: $OBJ
    # Owner means ESO owns the Secret and deletes it when this object goes away, which is what
    # makes the cleanup above sufficient. The alternative, Merge, writes into a Secret somebody
    # else owns - useful, and the wrong default for a test.
    creationPolicy: Owner
  data:
    - secretKey: canary
      remoteRef:
        key: $SELFTEST_PATH
        property: canary
YAML
[[ $? -eq 0 ]] || die "could not create the ExternalSecret - is the CRD installed?
  kubectl get crd externalsecrets.external-secrets.io"
ok 'created'

# ---------------------------------------------------------------- 4  did a Secret appear
step "waiting for Secret $PROBE_NS/$OBJ"
got=""
for i in $(seq 1 30); do
  got=$(kubectl -n "$PROBE_NS" get secret "$OBJ" -o jsonpath='{.data.canary}' 2>/dev/null)
  [[ -n "$got" ]] && break
  sleep 2
done

if [[ -z "$got" ]]; then
  bad 'no Secret after 60s'
  printf '%s    ExternalSecret status:%s\n' "$c_dim" "$c_off"
  kubectl -n "$PROBE_NS" get externalsecret "$OBJ" \
    -o jsonpath='{range .status.conditions[*]}      {.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null
  die "The operator did not produce a Secret. Its own logs name the reason, and the three
usual ones are a Vault role that does not permit the path, a NetworkPolicy drop, and a sealed
Vault:
  kubectl -n $ESO_NS logs deploy/external-secrets --tail=40
  make vault-bootstrap
  make vault-status"
fi
ok 'Secret materialised'

# ---------------------------------------------------------------- 5  the bytes
step 'the Secret holds the value written to Vault in this run'
decoded=$(printf '%s' "$got" | base64 -d 2>/dev/null)
if [[ "$decoded" == "$CANARY" ]]; then
  ok "$CANARY  - byte for byte"
else
  bad "Vault was given '$CANARY' and the Secret holds '$decoded'"
  die "A Secret exists and does not carry this run's value. That is a stale Secret, not a
working path - which is exactly what a check comparing against a fixed string would have passed."
fi

owner=$(kubectl -n "$PROBE_NS" get secret "$OBJ" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}' 2>/dev/null)
same "owned by $owner, so deleting the ExternalSecret removes it"

echo
printf '%sthe path from Vault to a pod-readable Secret works%s\n\n' "$c_ok" "$c_off"
printf 'What was proven, in order: the store authenticates to Vault as %s/%s; a value\n' "$ESO_NS" "$ESO_SA"
printf 'written to Vault seconds ago came out of a Kubernetes Secret in a different namespace.\n'
printf 'The ExternalSecret that did it names no substrate, which is the property ADR-0018 chose\n'
printf 'this option for.\n\n'
if [[ "$POLICY_VERIFIED" == yes ]]; then
  printf 'The Vault NetworkPolicy was also checked against the pod that did the talking.\n\n'
else
  printf '%sNot checked:%s whether a NetworkPolicy restricts who may reach Vault - see the warning\n' "$c_warn" "$c_off"
  printf 'above. The path works; who ELSE can use it is unestablished.\n\n'
fi
printf '%sStill true, and still a cost:%s ESO talks to Vault over plain HTTP (tls_disable = 1).\n' "$c_warn" "$c_off"
printf 'The NetworkPolicy reduces who can listen; it does not encrypt anything. Module 08.\n\n'
printf 'The probe objects are being deleted now. Nothing is left in %s.\n' "$PROBE_NS"
