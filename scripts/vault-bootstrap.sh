#!/usr/bin/env bash
# Configure Vault's INSIDE: the KV mount, the Kubernetes auth method, the policy, and the role
# External Secrets logs in with.
#
#   make vault-bootstrap        idempotent, safe to re-run, prints what it changed
#
# ADR-0018 Decision 4 calls this the fifth kind of state. Terraform owns Layer 0, Ansible owns
# Layer 1 and the Argo CD install, Argo CD owns in-cluster objects - and none of them can own
# this, because it lives inside an application and is reachable only through that application's
# own API. No Kubernetes manifest expresses "KV v2 is mounted at secret/".
#
# So it gets an explicit owner rather than a shell script nobody explains. This is that owner,
# and it is the one place in this project where imperative configuration is the correct answer
# instead of a shortcut.
#
# THE DIRECTION OF TRUTH, which is the design decision in this file:
#
# Nothing below is hardcoded from what the ClusterSecretStore ought to say. The store is read OUT
# OF THE CLUSTER and Vault is configured to match it. Git describes the arrangement, Argo CD
# applies the store, and this reconciles Vault to the store. A role name changed in Git plus a
# re-run stays consistent; a role name hardcoded here would drift silently, and the symptom would
# be a permission denial on an identity that looks correct in both places.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# A failed `source` returns nonzero and then execution simply CONTINUES, since this script does
# not use `set -e` (it cannot: `vault status` exits 2 on the normal sealed state). Without the
# guard the next hundred lines run against undefined functions and the first symptom is
# "vault_require_ready: command not found" after the banner has already printed.
LIB="$REPO_ROOT/scripts/vault-exec.lib.sh"
[[ -r "$LIB" ]] || { echo "missing $LIB - is this a complete checkout?" >&2; exit 1; }
# shellcheck source=scripts/vault-exec.lib.sh
source "$LIB"

STORE_NAME="${STORE_NAME:-vault-backend}"
POLICY_NAME=external-secrets-read

# The KV prefixes ESO may read. Everything else in Vault is closed to it, including by accident.
#
#   platform/   this platform's own values - the selftest canary, and whatever Module 08 adds
#   shopverse/  the tenant's six credentials
#
# A new tenant means a line here plus a re-run, which is friction on purpose: a ClusterSecretStore
# is ONE identity for the whole cluster (see the template that renders it), so this list is the
# only thing standing between ESO and every secret in Vault.
ALLOWED_PREFIXES=(platform shopverse)

SELFTEST_PATH=platform/eso-selftest
# A path NO rule in the policy covers, used to prove the policy denies rather than only permits.
FORBIDDEN_PATH=nowhere/denied-on-purpose

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
same() { printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; }
warn() { printf '    %s%s%s\n' "$c_warn" "$*" "$c_off"; }
bad()  { printf '    %s%s%s\n' "$c_err" "$*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

command -v jq >/dev/null || die "jq not installed - run: make tools"

printf '%sVault bootstrap%s\n\n' "$c_step" "$c_off"

# ---------------------------------------------------------------- 0  Vault must be usable
step 'Vault is initialised and unsealed'
vault_require_ready || exit 1
vault_load_root_token || exit 1
ok "$VAULT_NS/$VAULT_POD is unsealed; root token read from $VAULT_KEYS (never printed)"

# ---------------------------------------------------------------- 1  read the arrangement from Git-via-cluster
step "reading the arrangement from ClusterSecretStore/$STORE_NAME"
store=$(kubectl get clustersecretstore "$STORE_NAME" -o json 2>/dev/null)
[[ -n "$store" ]] || die "no ClusterSecretStore named $STORE_NAME.

That object is what this script configures Vault to match, so there is nothing to do until it
exists. External Secrets may not have synced yet:
  make gitops-refresh && make gitops-status
  kubectl get clustersecretstore"

q() { printf '%s' "$store" | jq -r "$1 // \"\""; }
KV_MOUNT=$(q '.spec.provider.vault.path')
KV_VERSION=$(q '.spec.provider.vault.version')
VAULT_ADDR_IN_STORE=$(q '.spec.provider.vault.server')
AUTH_MOUNT=$(q '.spec.provider.vault.auth.kubernetes.mountPath')
ROLE=$(q '.spec.provider.vault.auth.kubernetes.role')
ESO_SA=$(q '.spec.provider.vault.auth.kubernetes.serviceAccountRef.name')
ESO_SA_NS=$(q '.spec.provider.vault.auth.kubernetes.serviceAccountRef.namespace')

[[ -n "$KV_MOUNT" ]]   || die "$STORE_NAME has no .spec.provider.vault.path - is it a Vault store?"
[[ -n "$ROLE" ]]       || die "$STORE_NAME has no auth.kubernetes.role"
[[ -n "$ESO_SA" && -n "$ESO_SA_NS" ]] || die "$STORE_NAME has no auth.kubernetes.serviceAccountRef"
AUTH_MOUNT=${AUTH_MOUNT:-kubernetes}

# v1 and v2 are different APIs, not a version number: v2 reads from `<mount>/data/<path>`, v1 from
# `<mount>/<path>`. The policy below is written for v2, so a v1 store would get a policy granting
# access to paths that do not exist and a denial on every real read.
[[ "$KV_VERSION" == "v2" ]] || die "this script writes a KV **v2** policy, and $STORE_NAME says version=${KV_VERSION:-unset}.

v2 reads $KV_MOUNT/data/<path>; v1 reads $KV_MOUNT/<path>. A policy for the wrong one grants
nothing and denies everything, with paths that look right in both places."

ok "mount $KV_MOUNT ($KV_VERSION), auth at $AUTH_MOUNT, role $ROLE"
ok "identity: serviceaccount $ESO_SA_NS/$ESO_SA"
same "store points Vault at: $VAULT_ADDR_IN_STORE"

# ---------------------------------------------------------------- 2  the two RBAC facts this depends on
step 'the Kubernetes side of the auth chain'

# Vault's OWN service account, taken from the StatefulSet rather than guessed from the chart.
VAULT_SA=$(kubectl -n "$VAULT_NS" get statefulset vault \
           -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)
[[ -n "$VAULT_SA" ]] || die "could not read Vault's serviceAccountName from statefulset/vault in $VAULT_NS"

# THIS is the check that matters, and it is a check rather than an assumption on purpose.
#
# Kubernetes auth works by Vault calling the TokenReview API to ask "is this token real, and whose
# is it?". That call is made as Vault's own service account, which therefore needs
# system:auth-delegator. The HashiCorp chart creates that binding by default - and "by default"
# is exactly the kind of claim that has been wrong five times this week, so it is verified against
# the API server instead of against the chart's README.
#
# Without it, every ESO login fails with a message about the token being invalid. Nothing in that
# message mentions RBAC.
if kubectl auth can-i create tokenreviews.authentication.k8s.io \
     --as="system:serviceaccount:$VAULT_NS:$VAULT_SA" >/dev/null 2>&1; then
  ok "$VAULT_NS/$VAULT_SA can create TokenReviews (so Vault can verify a presented token)"
else
  bad "$VAULT_NS/$VAULT_SA CANNOT create TokenReviews"
  die "Vault cannot verify any service account token, so every External Secrets login will fail
with a message about the token rather than about permissions.

The HashiCorp chart normally creates this binding (server.authDelegator.enabled). Check:
  kubectl get clusterrolebinding -o json | jq -r '
    .items[] | select(.roleRef.name==\"system:auth-delegator\")
    | .metadata.name + \" -> \" + (.subjects // [] | map(.namespace + \"/\" + .name) | join(\",\"))'"
fi

kubectl -n "$ESO_SA_NS" get serviceaccount "$ESO_SA" >/dev/null 2>&1 \
  || die "no serviceaccount $ESO_SA_NS/$ESO_SA.

The ClusterSecretStore names an identity that does not exist. Most likely the External Secrets
chart's release name produced a different service account name than the overlay expects:
  kubectl -n $ESO_SA_NS get serviceaccount"
ok "serviceaccount $ESO_SA_NS/$ESO_SA exists"

# The other half of the chain: ESO mints a token for itself via the TokenRequest API.
#
# `--subresource=token`, NOT `serviceaccounts/token`. The first version of this check wrote
# `kubectl auth can-i create serviceaccounts/token`, and `auth can-i` parses `resource/name` as a
# resource and a RESOURCE NAME - so it asked "may you create a ServiceAccount called token?",
# correctly answered no, and I read it as an answer about TokenRequest. ESO's ClusterRole grants
# `create` on `serviceaccounts/token` with no resourceNames, so the permission was there the
# whole time.
#
# A new failure shape for the collection, and a worse one than the usual: not a check that
# confirms a request was recorded, but **a check whose "no" does not mean no**. It reported a
# problem that did not exist and became the leading hypothesis for an unrelated failure.
#
# Hence three outcomes rather than two. If the answer cannot be obtained - an older kubectl with
# no --subresource flag, no impersonation permission - that is reported as NOT KNOWN, because a
# check that cannot tell must not say "no".
sa_token_check=$(kubectl auth can-i create serviceaccounts --subresource=token -n "$ESO_SA_NS" \
                 --as="system:serviceaccount:$ESO_SA_NS:$ESO_SA" 2>&1)
case "$sa_token_check" in
  yes*) ok "$ESO_SA_NS/$ESO_SA can mint its own tokens (TokenRequest)" ;;
  no*)  warn "$ESO_SA_NS/$ESO_SA cannot create serviceaccounts/token (TokenRequest)"
        warn 'ESO may not be able to obtain the token it presents to Vault. Continuing - the login'
        warn 'test at the end will say whether this actually matters.' ;;
  *)    warn 'could not determine whether ESO can mint its own token:'
        printf '      %s%s%s\n' "$c_dim" "${sa_token_check%%$'\n'*}" "$c_off"
        warn 'Treating that as UNKNOWN rather than as a denial.' ;;
esac

# ---------------------------------------------------------------- 3  KV v2 at the mount
step "KV v2 at $KV_MOUNT/"
mounts=$(vsh 'vault secrets list -format=json') || die "could not list Vault's secret mounts"
existing_type=$(printf '%s' "$mounts" | jq -r --arg m "$KV_MOUNT/" '.[$m].type // ""')
existing_ver=$(printf '%s' "$mounts" | jq -r --arg m "$KV_MOUNT/" '.[$m].options.version // ""')

if [[ -z "$existing_type" ]]; then
  # Not the default. A dev-mode Vault mounts KV v2 at secret/ for you, which is why every
  # tutorial skips this step and why a real Vault then returns 404 on a path that works in every
  # example (ADR-0018 Decision 2 chose not to use dev mode precisely so this is visible).
  vsh 'vault secrets enable -path="$1" kv-v2' "$KV_MOUNT" >/dev/null \
    || die "could not enable kv-v2 at $KV_MOUNT/"
  ok "enabled kv-v2 at $KV_MOUNT/"
elif [[ "$existing_type" == "kv" && "$existing_ver" == "2" ]]; then
  same "already kv v2 - unchanged"
else
  die "$KV_MOUNT/ exists as type=$existing_type version=${existing_ver:-1}, not kv v2.

This is not fixable by re-running. A v1 mount cannot be upgraded in place without moving the
data, and the policy this script writes addresses $KV_MOUNT/data/* which does not exist on v1.
Either point the store at a different mount or migrate deliberately."
fi

# ---------------------------------------------------------------- 4  the Kubernetes auth method
step "Kubernetes auth method at auth/$AUTH_MOUNT/"
auths=$(vsh 'vault auth list -format=json') || die "could not list Vault's auth methods"
if [[ -z "$(printf '%s' "$auths" | jq -r --arg m "$AUTH_MOUNT/" '.[$m].type // ""')" ]]; then
  vsh 'vault auth enable -path="$1" kubernetes' "$AUTH_MOUNT" >/dev/null \
    || die "could not enable the kubernetes auth method at $AUTH_MOUNT/"
  ok "enabled the kubernetes auth method"
else
  same 'already enabled - unchanged'
fi

# One field. That is the finding worth recording, because the documented examples carry three.
#
# token_reviewer_jwt and kubernetes_ca_cert are NOT set, and must not be: when they are omitted,
# Vault reads the token and CA from its own pod's
# /var/run/secrets/kubernetes.io/serviceaccount/ and RE-READS them periodically. Pinning a JWT
# into the config instead would work until that token expired - which, with projected
# short-lived tokens, is hours - and then every login would fail for a reason unrelated to
# anything that changed. (Vault before 1.9.3 read them once at config time, which is where the
# three-field examples come from.)
#
# The host comes from the pod's own environment, expanded INSIDE the pod. That is why the program
# is single-quoted here: expanding it in this shell would substitute the workstation's empty
# variables and write `https://:` into Vault's config.
step "configuring auth/$AUTH_MOUNT/config"
vsh 'vault write auth/"$1"/config kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"' \
    "$AUTH_MOUNT" >/dev/null || die "could not write auth/$AUTH_MOUNT/config"
cfg_host=$(vsh 'vault read -field=kubernetes_host auth/"$1"/config' "$AUTH_MOUNT")

# The read-back is not decoration, and the first version of this line made it decoration: it
# printed the value and asserted nothing. A stub run produced `https://:` - both variables empty,
# because the program had been expanded on the workstation instead of inside the pod - and the
# script went on to report the chain proven. Every login would then fail against a host that is
# not a host, and the only evidence was a line of output nobody would question.
#
# So the shape is asserted. `https://<addr>:<port>` with both halves non-empty.
if [[ ! "$cfg_host" =~ ^https://[^:/]+:[0-9]+$ ]]; then
  bad "kubernetes_host = '$cfg_host'"
  die "That is not an address Vault can reach, so no login will ever succeed.

An empty host or port means \$KUBERNETES_SERVICE_HOST and \$KUBERNETES_SERVICE_PORT were not set
when the write happened. They are injected into every pod by the kubelet, so the usual cause is
the program being expanded on this workstation rather than inside the pod - the write above is
single-quoted for exactly that reason.

What the pod itself reports:
  kubectl -n $VAULT_NS exec $VAULT_POD -- sh -c 'echo \$KUBERNETES_SERVICE_HOST:\$KUBERNETES_SERVICE_PORT'"
fi
ok "kubernetes_host = $cfg_host  (read back and checked, not assumed)"

# ---------------------------------------------------------------- 5  the policy
step "policy $POLICY_NAME"
policy_hcl=""
for p in "${ALLOWED_PREFIXES[@]}"; do
  # Both halves are needed and the second is the one people forget. In KV v2 a secret's VALUE
  # lives under data/ and its versions, deletion state and custom metadata live under metadata/ -
  # so a policy with only the data rule works for a read and fails the moment anything lists.
  policy_hcl+=$(printf 'path "%s/data/%s/*" {\n  capabilities = ["read"]\n}\n\npath "%s/metadata/%s/*" {\n  capabilities = ["read", "list"]\n}\n\n' \
                "$KV_MOUNT" "$p" "$KV_MOUNT" "$p")
done

# The policy is multi-line HCL and `vault policy write name -` reads it from stdin - but stdin
# inside the pod is already carrying the root token. Rather than nest a heredoc inside an `eval`
# (which works in most shells and is a poor thing to depend on in a container whose shell is
# busybox), the HCL travels as a single base64 argument and is decoded in the pod. One line in,
# one pipe, no quoting questions. Policy text is not a secret, so argv is fine for it.
policy_b64=$(printf '%s' "$policy_hcl" | base64 | tr -d '\n')
vsh 'printf %s "$2" | base64 -d | vault policy write "$1" -' "$POLICY_NAME" "$policy_b64" >/dev/null \
  || die "could not write policy $POLICY_NAME"
for p in "${ALLOWED_PREFIXES[@]}"; do ok "read-only: $KV_MOUNT/data/$p/*"; done

# ---------------------------------------------------------------- 6  the role
step "role $ROLE"
# bound_service_account_names and _namespaces are the binding: a token from any OTHER service
# account is rejected even though it is a perfectly valid Kubernetes token. That is the whole
# security property of this auth method, and it is one line.
#
# `default` is in token_policies deliberately. It grants a token the ability to look itself up,
# renew and revoke itself, and to query which secret mounts exist - which the `vault kv` CLI
# needs to decide whether a mount is v1 or v2. Without it the verification below fails on the
# mount lookup rather than on the secret, and reads as a permission problem with the policy.
vsh 'vault write auth/"$1"/role/"$2" \
       bound_service_account_names="$3" \
       bound_service_account_namespaces="$4" \
       token_policies="default,$5" \
       token_ttl=1h' \
    "$AUTH_MOUNT" "$ROLE" "$ESO_SA" "$ESO_SA_NS" "$POLICY_NAME" >/dev/null \
  || die "could not write auth/$AUTH_MOUNT/role/$ROLE"

role_json=$(vsh 'vault read -format=json auth/"$1"/role/"$2"' "$AUTH_MOUNT" "$ROLE")
ok "bound to $(printf '%s' "$role_json" | jq -r '.data.bound_service_account_namespaces | join(",")')/$(printf '%s' "$role_json" | jq -r '.data.bound_service_account_names | join(",")')"
ok "policies: $(printf '%s' "$role_json" | jq -r '.data.token_policies | join(", ")')"

# ---------------------------------------------------------------- 7  something to read
step "seeding $KV_MOUNT/$SELFTEST_PATH"
# The verification below needs a path that EXISTS and is permitted, because a read of a missing
# path inside an allowed prefix returns 404 - which fails, and would be mistaken for a denial.
# This canary is also what `make eso-check` overwrites with a fresh value each run.
vsh 'vault kv put -mount="$1" "$2" canary=bootstrap seeded-by=vault-bootstrap >/dev/null' \
    "$KV_MOUNT" "$SELFTEST_PATH" || die "could not write $KV_MOUNT/$SELFTEST_PATH"
ok 'wrote a canary (a placeholder value, not a credential)'

# ---------------------------------------------------------------- 8  prove the whole chain
step 'logging in AS External Secrets, to prove the chain end to end'
# Everything above is a request Vault recorded. This is the only part that shows the arrangement
# WORKS - and it tests it the way ESO will, rather than the way this script has been talking to
# Vault. The root token proves nothing about the role.
#
# Three results, and the third is what makes the first two mean anything:
#
#   LOGIN_OK      Kubernetes auth + TokenReview + the role's bindings all line up
#   ALLOWED_OK    the policy permits a path it should
#   DENIED_OK     the policy DENIES a path it should not - with "permission denied" specifically,
#                 because a 404 would also make the read fail and would prove nothing
jwt=$(kubectl -n "$ESO_SA_NS" create token "$ESO_SA" --duration=10m 2>/dev/null)
[[ -n "$jwt" ]] || die "could not mint a token for $ESO_SA_NS/$ESO_SA (kubectl create token)"

# The JWT goes on stdin, not in argv - same reasoning as the root token, and this helper sends no
# token of its own so stdin is free for it.
probe=$(printf '%s\n' "$jwt" | vsh_unauth '
  read -r J
  T=$(printf %s "$J" | vault write -field=token auth/"$1"/login role="$2" jwt=- 2>&1) || {
    printf "LOGIN_FAILED %s\n" "$T"
    exit 0
  }
  printf "LOGIN_OK\n"
  VAULT_TOKEN=$T; export VAULT_TOKEN
  if vault kv get -mount="$3" "$4" >/dev/null 2>&1; then
    printf "ALLOWED_OK\n"
  else
    printf "ALLOWED_FAILED\n"
  fi
  if M=$(vault kv get -mount="$3" "$5" 2>&1); then
    printf "DENIED_OPEN\n"
  else
    case "$M" in
      *"permission denied"*) printf "DENIED_OK\n" ;;
      *) printf "DENIED_UNCLEAR %s\n" "$M" ;;
    esac
  fi
  vault token revoke -self >/dev/null 2>&1 && printf "REVOKED\n" || printf "REVOKE_FAILED\n"
' "$AUTH_MOUNT" "$ROLE" "$KV_MOUNT" "$SELFTEST_PATH" "$FORBIDDEN_PATH")

has() { printf '%s' "$probe" | grep -q "^$1"; }

if has LOGIN_OK; then
  ok "login as $ESO_SA_NS/$ESO_SA succeeded"
else
  bad 'login FAILED'
  printf '%s\n' "$probe" | sed 's/^/      /'
  die "The role exists and the policy exists, and the identity still cannot log in. Check, in
this order:
  1. TokenReview RBAC on $VAULT_NS/$VAULT_SA  (reported above)
  2. Vault reaching the API server:  kubectl -n $VAULT_NS exec $VAULT_POD -- sh -c 'wget -qO- -T3 \$KUBERNETES_SERVICE_HOST 2>&1 | head -1'
  3. the role's bindings vs the identity:  kubectl -n $VAULT_NS exec $VAULT_POD -- vault read auth/$AUTH_MOUNT/role/$ROLE"
fi

has ALLOWED_OK && ok "read $KV_MOUNT/$SELFTEST_PATH - permitted" \
               || bad "could NOT read $KV_MOUNT/$SELFTEST_PATH, which the policy permits"

if has DENIED_OK; then
  ok "read $KV_MOUNT/$FORBIDDEN_PATH - denied, and denied for the right reason"
elif has DENIED_OPEN; then
  bad "read $KV_MOUNT/$FORBIDDEN_PATH SUCCEEDED"
  die "The policy permits a path no rule in it covers, which means it is not the policy this
script thinks it wrote. Everything else above would still look correct - a role that can read
everything passes every permit test. This is the case that matters.
  kubectl -n $VAULT_NS exec $VAULT_POD -- vault policy read $POLICY_NAME"
else
  warn 'the forbidden read failed, but not with a permission denial:'
  printf '%s\n' "$probe" | grep '^DENIED' | sed 's/^/      /'
  warn 'A missing path fails too, and would prove nothing. So the policy has been shown to'
  warn 'permit what it should, and NOT yet shown to deny anything.'
fi

has REVOKED && same 'test token revoked' \
            || warn 'could not revoke the test token (it expires in an hour)'

if ! has ALLOWED_OK || ! has LOGIN_OK; then
  exit 1
fi

# ---------------------------------------------------------------- done
echo
printf '%sVault is configured and the chain is proven%s\n\n' "$c_ok" "$c_off"
printf 'What now exists inside Vault, which no manifest in this repository describes:\n\n'
printf '    %s/            kv v2\n' "$KV_MOUNT"
printf '    auth/%s/   configured from the pod'"'"'s own service account token\n' "$AUTH_MOUNT"
printf '    policy %s   read-only on %d prefix(es)\n' "$POLICY_NAME" "${#ALLOWED_PREFIXES[@]}"
printf '    role %s     bound to %s/%s\n\n' "$ROLE" "$ESO_SA_NS" "$ESO_SA"
printf 'This is re-runnable and reports "unchanged" when nothing moved, which is the only reason\n'
printf 'an imperative step is acceptable here (ADR-0018 Decision 4).\n\n'
printf '%sIf External Secrets was already running and failing%s - which it is, on a first run, because\n' "$c_warn" "$c_off"
printf 'the role above did not exist until a moment ago - it is in exponential backoff and its\n'
printf 'ClusterSecretStore still reports NotReady for up to a minute. That is the operator\n'
printf 'retrying, not a fault. `make eso-check` waits for it. To reset the backoff instead:\n'
printf '    kubectl -n %s rollout restart deploy/external-secrets\n\n' "$ESO_SA_NS"
printf 'Next:  make eso-check    - writes a FRESH value to Vault and proves it reaches a pod\n'
