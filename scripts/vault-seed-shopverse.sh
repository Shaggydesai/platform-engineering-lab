#!/usr/bin/env bash
# Move ShopVerse's SIX EXISTING credentials into Vault, unchanged, and prove they come back out.
#
#   make vault-seed-shopverse
#
# ADR-0018 Decision 5 is the whole reason this is a script and not a command someone types:
#
#   **the existing values, never fresh ones.**
#
# `mongo-password` initialised MongoDB's root user on the volume's FIRST BOOT ONLY. Generating new
# values during the migration would leave every service authenticating against a database that
# still expects the old password - and that failure presents as a healthy, Running, Ready MongoDB
# refusing connections, which reads like a connection-string bug for about an hour.
# `make shopverse-secret` already refuses to cause that; this must not reintroduce it.
#
# So the source of truth is the Secret IN THE CLUSTER. Nothing here generates anything.
#
# WHAT THIS DOES NOT DO: it does not flip `externalSecret.enabled`. That is a separate, deliberate
# commit, and the order is not negotiable (ADR-0018 Decision 6) - Vault populated and verified
# first, because flipping the flag changes every Deployment's secretKeyRef from
# `shopverse-credentials` to `shopverse-secrets`, and doing that before the new Secret can exist
# gives seven pods a reference to nothing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LIB="$REPO_ROOT/scripts/vault-exec.lib.sh"
[[ -r "$LIB" ]] || { echo "missing $LIB - is this a complete checkout?" >&2; exit 1; }
# shellcheck source=scripts/vault-exec.lib.sh
source "$LIB"

APP=gitops/clusters/onprem/apps/shopverse.yaml
OVERLAY=gitops/environments/onprem/shopverse.yaml
STORE_NAME="${STORE_NAME:-vault-backend}"
PROBE_NS="${PROBE_NS:-default}"
PROBE=shopverse-seed-preflight

# The six keys, in the chart's own order. NOT a guess: this list is the `range` in
# helm/shopverse/templates/externalsecret.yaml at the pinned commit, and the script asserts the
# source Secret carries exactly these - no extras, none missing - rather than copying whatever
# happens to be there. A seventh key appearing in the Secret and not in the chart would otherwise
# migrate silently and be dropped silently.
KEYS=(jwt-secret internal-token admin-email admin-password mongo-username mongo-password)

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
same() { printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; }
warn() { printf '    %s%s%s\n' "$c_warn" "$*" "$c_off"; }
bad()  { printf '    %s%s%s\n' "$c_err" "$*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

command -v jq >/dev/null || die "jq not installed - run: make tools"
command -v yq >/dev/null || die "yq not installed - run: make tools"
command -v sha256sum >/dev/null || die "sha256sum not found - this script verifies by hash"

cleanup() {
  kubectl -n "$PROBE_NS" delete externalsecret "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$PROBE_NS" delete secret "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '%sSeeding Vault with ShopVerse'"'"'s existing credentials%s\n\n' "$c_step" "$c_off"

# ---------------------------------------------------------------- 0  where everything is
step 'reading the arrangement from Git and the cluster'
NS=$(yq -r '.spec.destination.namespace' "$APP")
SRC=$(yq -r '.secrets.existingSecret' "$OVERLAY")
REMOTE_KEY=$(yq -r '.externalSecret.remoteKey // ""' "$OVERLAY")
[[ -n "$NS"  && "$NS"  != "null" ]] || die "no destination namespace in $APP"
[[ -n "$SRC" && "$SRC" != "null" ]] || die "no secrets.existingSecret in $OVERLAY"
[[ -n "$REMOTE_KEY" ]] || die "no externalSecret.remoteKey in $OVERLAY.

That value is the Vault path the chart will read, so this script has nowhere to write to. It is
set in the same commit that adds this script; if it is missing, the checkout is partial."

store=$(kubectl get clustersecretstore "$STORE_NAME" -o json 2>/dev/null)
[[ -n "$store" ]] || die "no ClusterSecretStore named $STORE_NAME - run: make eso-check"
KV_MOUNT=$(printf '%s' "$store" | jq -r '.spec.provider.vault.path // ""')
[[ -n "$KV_MOUNT" ]] || die "$STORE_NAME is not a Vault store"

ok "source:      secret/$SRC in namespace $NS"
ok "destination: $KV_MOUNT/$REMOTE_KEY in Vault"
same "the chart reads that path once externalSecret.enabled is true"

# The Vault policy must already permit the prefix, or ESO will be denied after the flip. Cheap to
# check here, where it is one line of output, rather than after seven Deployments have rolled.
case "$REMOTE_KEY" in
  shopverse/*) ok "inside the policy prefix $KV_MOUNT/data/shopverse/*" ;;
  *) die "remoteKey '$REMOTE_KEY' is outside the prefixes ESO is allowed to read.

scripts/vault-bootstrap.sh grants read on $KV_MOUNT/data/platform/* and $KV_MOUNT/data/shopverse/*
only. Writing here would succeed (this script uses the root token) and ESO would be denied after
the flag is flipped - a permission failure on a path that looks correct in both places." ;;
esac

vault_require_ready || exit 1
vault_load_root_token || exit 1

# ---------------------------------------------------------------- 1  the existing values
step "reading the six existing values from $NS/$SRC"
src_json=$(kubectl -n "$NS" get secret "$SRC" -o json 2>/dev/null) \
  || die "no Secret $SRC in $NS.

This script COPIES; it does not generate. If the Secret genuinely does not exist, the bootstrap
path is:  make shopverse-secret
But if ShopVerse is running, the Secret exists and something else is wrong - check the namespace."

# Exactly these keys. Extras and omissions are both failures, and for opposite reasons: a missing
# key means the app will break after the flip, an extra one means something is in the Secret that
# the chart does not know about and that this migration would quietly drop.
present=$(printf '%s' "$src_json" | jq -r '.data | keys_unsorted[]' | sort)
expected=$(printf '%s\n' "${KEYS[@]}" | sort)
if [[ "$present" != "$expected" ]]; then
  bad 'the Secret does not hold exactly the six keys the chart reads'
  printf '      %sin the Secret:%s %s\n' "$c_dim" "$c_off" "$(printf '%s' "$present" | tr '\n' ' ')"
  printf '      %sthe chart reads:%s %s\n' "$c_dim" "$c_off" "$(printf '%s' "$expected" | tr '\n' ' ')"
  die "Reconcile these before migrating. A key the chart reads and Vault lacks becomes a pod that
cannot start; a key in the Secret that the chart ignores becomes a value nobody notices is gone."
fi
ok "all six present, and nothing else"

# Hash each source value. Hashing is what lets the verification be printed without the values
# being printed.
#
# `$(cat)` strips trailing newlines, and that is load-bearing rather than tidy. The verification
# below hashes each value INSIDE the Vault pod, via `vault kv get -field=<key>` - and whether that
# CLI appends a newline to a -field value has differed between Vault versions. The first stub run
# reported all six values DIFFERENT for exactly that reason: same bytes, one side with a trailing
# newline, six confident mismatches.
#
# So both sides are normalised the same way and the comparison is newline-insensitive. The honest
# caveat: a credential whose value genuinely ENDED in a newline would compare equal to one that
# did not. This affects only the check - the write itself is JSON, so Vault stores the exact
# bytes - and the six values here are hex strings and an email address.
h_local() { printf '%s' "$(cat)" | sha256sum | cut -d' ' -f1; }

declare -A SRC_HASH
for k in "${KEYS[@]}"; do
  SRC_HASH[$k]=$(printf '%s' "$src_json" | jq -r --arg k "$k" '.data[$k]' | base64 -d | h_local)
done
same "hashed locally so the rest of this run can compare without printing anything"

# ---------------------------------------------------------------- 2  is Vault already holding these?
step "checking what $KV_MOUNT/$REMOTE_KEY already holds"
existing=$(vsh 'vault kv get -mount="$1" -format=json "$2" 2>/dev/null || true' "$KV_MOUNT" "$REMOTE_KEY")
if [[ -n "$existing" ]] && printf '%s' "$existing" | jq -e '.data.data' >/dev/null 2>&1; then
  drift=0
  for k in "${KEYS[@]}"; do
    h=$(vsh 'printf %s "$(vault kv get -mount="$1" -field="$3" "$2" 2>/dev/null)" | sha256sum | cut -d" " -f1' \
        "$KV_MOUNT" "$REMOTE_KEY" "$k")
    [[ "$h" == "${SRC_HASH[$k]}" ]] || drift=$((drift + 1))
  done
  if (( drift == 0 )); then
    same 'already holds exactly these six values - this run will change nothing'
  else
    warn "already holds $drift value(s) that DIFFER from the cluster's Secret"
    warn 'Overwriting with the cluster values, which is the correct direction: the running'
    warn 'MongoDB was initialised from the Secret, so the Secret is authoritative and a'
    warn 'differing value in Vault is the stale one. ADR-0018 Decision 5.'
  fi
else
  same 'nothing there yet'
fi

# ---------------------------------------------------------------- 3  write them
step "writing six values to $KV_MOUNT/$REMOTE_KEY"
# As JSON on STDIN. `vault kv put path key=value` would place all six credentials in the pod's
# argv - visible to `ps` in the container and recorded in the API server's audit log of the exec
# request. The payload goes down the same pipe as the token instead (vsh_payload).
payload=$(printf '%s' "$src_json" | jq '.data | map_values(@base64d)')
# One sanity assertion on the payload before it leaves this shell: six keys, all non-empty. An
# empty value would be written happily and would break a service in a way that looks like a bug
# in the service.
n_empty=$(printf '%s' "$payload" | jq '[to_entries[] | select(.value == "")] | length')
[[ "$(printf '%s' "$payload" | jq 'keys | length')" == "6" && "$n_empty" == "0" ]] \
  || die "refusing to write: the payload has $n_empty empty value(s)"

printf '%s' "$payload" | vsh_payload 'vault kv put -mount="$1" "$2" - >/dev/null' "$KV_MOUNT" "$REMOTE_KEY" \
  || die "the write failed. Vault is unsealed and the root token was accepted earlier, so check:
  kubectl -n $VAULT_NS logs $VAULT_POD --tail=20"
ok 'written'

# ---------------------------------------------------------------- 4  verify, by hash, in the pod
step 'verifying each value against the cluster Secret'
# The hash is computed INSIDE the pod, so the values never cross the network a second time. A
# value that disagrees is the only thing that matters here, and the hash is enough to say so
# without either value being displayed.
fail=0; unknown=0
for k in "${KEYS[@]}"; do
  h=$(vsh 'printf %s "$(vault kv get -mount="$1" -field="$3" "$2")" | sha256sum | cut -d" " -f1' \
      "$KV_MOUNT" "$REMOTE_KEY" "$k")
  if [[ ! "$h" =~ ^[0-9a-f]{64}$ ]]; then
    # Not a hash. sha256sum or cut missing from the image, or the read failed - either way this
    # is NOT a mismatch and must not be reported as one (the lesson from the auth can-i bug).
    warn "$k: could not obtain a hash from the pod - verification UNKNOWN for this key"
    unknown=$((unknown + 1))
  elif [[ "$h" == "${SRC_HASH[$k]}" ]]; then
    ok "$k  ${h:0:12}  matches"
  else
    bad "$k  vault=${h:0:12}  secret=${SRC_HASH[$k]:0:12}  DIFFERENT"
    fail=$((fail + 1))
  fi
done
(( fail == 0 )) || die "$fail value(s) in Vault differ from the cluster's Secret. Do NOT flip
externalSecret.enabled: the pods would authenticate against MongoDB with a password it was not
initialised with, and MongoDB would stay Running and Ready while refusing every connection."
(( unknown == 0 )) || warn "$unknown key(s) unverified - treat the migration as unproven"

# ---------------------------------------------------------------- 5  can ESO actually read it
step 'proving External Secrets can read that path, BEFORE anything is flipped'
# This is the step that makes the flip safe. It builds the same ExternalSecret the chart will -
# one remoteKey, six properties, the same ClusterSecretStore - but targets a scratch Secret in
# another namespace. So the Vault path, the six property names and ESO's read permission are all
# exercised while ShopVerse keeps running on the Secret it already has.
#
# What it cannot prove: that the chart's template matches this one. The property names here were
# read out of helm/shopverse/templates/externalsecret.yaml at the pinned commit rather than
# recalled, and the remoteKey comes from the overlay the chart will use - but it is a replica, and
# a replica that agrees with a template is evidence, not proof. The residual risk is one flag
# flip away from being rolled back.
kubectl apply -f - >/dev/null <<YAML
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: $PROBE
  namespace: $PROBE_NS
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: $STORE_NAME
  target:
    name: $PROBE
    creationPolicy: Owner
  data:
$(for k in "${KEYS[@]}"; do printf '    - secretKey: %s\n      remoteRef:\n        key: %s\n        property: %s\n' "$k" "$REMOTE_KEY" "$k"; done)
YAML
[[ $? -eq 0 ]] || die "could not create the preflight ExternalSecret"

got=""
for _ in $(seq 1 30); do
  got=$(kubectl -n "$PROBE_NS" get secret "$PROBE" -o json 2>/dev/null)
  [[ -n "$got" ]] && break
  sleep 2
done
if [[ -z "$got" ]]; then
  bad 'ESO did not produce a Secret from that path within 60s'
  kubectl -n "$PROBE_NS" get externalsecret "$PROBE" \
    -o jsonpath='{range .status.conditions[*]}      {.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null
  die "Do NOT flip externalSecret.enabled. The most likely causes, in order:
  the Vault policy does not cover $KV_MOUNT/data/$REMOTE_KEY   (make vault-bootstrap)
  the store is not Ready                                       (make eso-check)
  kubectl -n external-secrets logs deploy/external-secrets --tail=30"
fi

pfail=0
for k in "${KEYS[@]}"; do
  h=$(printf '%s' "$got" | jq -r --arg k "$k" '.data[$k] // ""' | base64 -d 2>/dev/null | h_local)
  if [[ "$h" == "${SRC_HASH[$k]}" ]]; then
    ok "$k  arrived intact"
  else
    bad "$k  did NOT arrive intact"
    pfail=$((pfail + 1))
  fi
done
(( pfail == 0 )) || die "$pfail of 6 keys did not survive the round trip through Vault and ESO.
Do NOT flip the flag."

echo
printf '%sall six credentials are in Vault and External Secrets can read them back%s\n\n' "$c_ok" "$c_off"
printf 'Nothing has changed for the running application. %sShopVerse is still using\n' "$c_dim"
printf '%s/%s%s, and that Secret has not been touched or deleted.\n\n' "$NS" "$SRC" "$c_off"
printf 'The flip is the next, separate step - and it IS a rollout (ADR-0018 Decision 6):\n'
printf '`shopverse.secretName` changes from %s to shopverse-secrets, so every\n' "$SRC"
printf 'Deployment'"'"'s secretKeyRef changes, so every pod template changes, so every pod is\n'
printf 'replaced. Expect the ~9 seconds of 502s per service that ADR-0016 measured.\n\n'
printf '  1. set externalSecret.enabled: true in %s\n' "$OVERLAY"
printf '  2. commit, push, make gitops-refresh\n'
printf '  3. make shopverse-check          the gate - a real order, end to end\n'
printf '  4. git grep for any of the values - there must be nothing\n\n'
printf '%sRollback is one flag.%s Setting it back to false returns the chart to %s,\n' "$c_warn" "$c_off" "$SRC"
printf 'which still exists. That is the reason this script does not delete it.\n'
