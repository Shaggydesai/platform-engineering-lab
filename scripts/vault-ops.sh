#!/usr/bin/env bash
# Vault's lifecycle operations: the parts no manifest can express.
#
#   make vault-status     is it initialised, is it sealed
#   make vault-init       one time only, writes the unseal keys to .cache/
#   make vault-unseal     after every cluster restart
#
# ADR-0018 Decision 3: the unseal keys are THE one secret that cannot be in Git, and
# .cache/vault-init.json is the only place they exist. Losing that file makes every secret in
# Vault unrecoverable - not inconvenient, unrecoverable.
#
# ADR-0018 Decision 4: Vault's internal state is a fifth kind, owned by neither Terraform,
# Ansible nor Argo CD. This script is that owner for the lifecycle half; vault-bootstrap handles
# auth methods and policies.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NS=vault
POD=vault-0
KEYS=.cache/vault-init.json
SHARES=5
THRESHOLD=3

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
warn() { printf '    %s%s%s\n' "$c_warn" "$*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

command -v jq >/dev/null || die "jq not installed - run: make tools"

v() { kubectl -n "$NS" exec "$POD" -- vault "$@"; }

# jq's alternative operator treats FALSE as empty, so asking for a boolean with a default
# returns the default exactly when the boolean is false - which here is when Vault is WORKING.
# The first version of this script used that idiom in four places, so `make vault-unseal` would
# have unsealed Vault successfully and then reported failure, every time. Found by running it
# against a stub, not by reading it.
#
# `tostring` has no such trap: "true", "false", or "null" for an absent key.
jbool() { jq -r "${1} | tostring" 2>/dev/null || echo null; }

require_pod() {
  kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1 \
    || die "$NS/$POD does not exist.
Argo CD may not have synced Vault yet:  make gitops-refresh && make gitops-status"
}

# `vault status` exits 0 unsealed, 2 SEALED, 1 on error - so a bare call under `set -e` would
# abort exactly when the answer is "sealed", which is the normal state this script exists to fix.
# The `|| true` is load-bearing, not defensive.
vault_status_json() {
  kubectl -n "$NS" exec "$POD" -- vault status -format=json 2>/dev/null || true
}

case "${1:-status}" in

status)
  require_pod
  st=$(vault_status_json)
  if [[ -z "$st" ]]; then
    die "could not read vault status. The pod exists but is not answering - check:
  kubectl -n $NS logs $POD --tail=30"
  fi
  init=$(printf '%s' "$st" | jbool .initialized)
  sealed=$(printf '%s' "$st" | jbool .sealed)
  ver=$(printf '%s' "$st" | jq -r '.version // "?"')
  printf '    initialised: %s\n    sealed:      %s\n    version:     %s\n' "$init" "$sealed" "$ver"
  if [[ "$init" == "false" ]]; then
    warn 'not initialised yet - run: make vault-init'
  elif [[ "$sealed" == "true" ]]; then
    warn 'sealed - run: make vault-unseal'
  else
    ok 'unsealed and serving'
  fi
  [[ -f "$KEYS" ]] && ok "keys present at $KEYS" || warn "$KEYS is MISSING"
  ;;

init)
  require_pod
  st=$(vault_status_json)
  init=$(printf '%s' "$st" | jbool .initialized)

  # Refusing is the important behaviour. `vault operator init` on an initialised Vault errors
  # anyway, but the dangerous case is the file: writing a NEW .cache/vault-init.json over an
  # existing one would discard the only copy of the real keys while appearing to succeed.
  if [[ "$init" == "true" ]]; then
    warn 'Vault is already initialised - nothing done.'
    if [[ -f "$KEYS" ]]; then
      printf '    %s and %s exists, so this cluster is recoverable.%s\n' "$c_dim" "$KEYS" "$c_off"
      printf '    Sealed? run: make vault-unseal\n'
    else
      die "...but $KEYS DOES NOT EXIST.

This is the bad case. Vault holds data it can only decrypt with keys that are not on this
machine. Re-initialising would NOT help - it would refuse, and if it did not it would destroy
the data. If the file is on another machine or in a password manager, restore it there.

If it is genuinely lost, the only path is to destroy Vault's volume and start again, which
loses every secret it held:
  kubectl -n $NS delete statefulset vault
  kubectl -n $NS delete pvc -l app.kubernetes.io/name=vault
  make gitops-refresh     # Argo CD recreates it
  make vault-init"
    fi
    exit 0
  fi

  if [[ -f "$KEYS" ]]; then
    die "$KEYS already exists but Vault reports itself UNINITIALISED.

Refusing to overwrite it. Either the file belongs to a previous Vault whose volume is gone - in
which case move it aside, since those keys unlock nothing - or this Vault lost its storage while
the keys survived. Decide which before continuing:
  mv $KEYS $KEYS.old && make vault-init"
  fi

  step "initialising Vault ($SHARES key shares, $THRESHOLD needed to unseal)"
  mkdir -p "$(dirname "$KEYS")"
  # The output of this command is unrecoverable. Written straight to the file, never echoed, and
  # with the mode set before the content lands.
  umask 077
  if ! v operator init -key-shares="$SHARES" -key-threshold="$THRESHOLD" -format=json > "$KEYS"; then
    rm -f "$KEYS"
    die "vault operator init failed; $KEYS removed so it cannot be mistaken for real keys"
  fi
  chmod 600 "$KEYS"
  n=$(jq -r '.unseal_keys_b64 | length' "$KEYS" 2>/dev/null || echo 0)
  if [[ "$n" != "$SHARES" ]]; then
    # Remove it. A file with the wrong number of keys is worse than none: the next run would
    # refuse to overwrite it, and it unlocks nothing.
    rm -f "$KEYS"
    die "expected $SHARES unseal keys from vault operator init, found $n - $KEYS removed"
  fi
  ok "$n unseal keys and a root token written to $KEYS (mode 600)"

  echo
  printf '%s  READ THIS ONCE.%s\n' "$c_warn" "$c_off"
  printf '  %s is now the only copy of the keys to every secret this platform\n' "$KEYS"
  printf '  will hold. It is gitignored and it exists nowhere else - not in Git, not in a\n'
  printf '  Secret, not in this terminal.\n\n'
  printf '  Copy it somewhere off this machine before Vault becomes authoritative. A password\n'
  printf '  manager entry is enough. If the laptop dies with this file on it, every secret in\n'
  printf '  Vault is unrecoverable, and no amount of cluster rebuilding brings it back.\n\n'
  printf '  This is not a flaw in Vault. Sealed Secrets and SOPS have the same property wearing\n'
  printf '  different clothes (ADR-0018). It is just the first file here where it is true.\n'
  echo
  step 'now unseal it'
  printf '    make vault-unseal\n'
  ;;

unseal)
  require_pod
  [[ -f "$KEYS" ]] || die "$KEYS not found - cannot unseal.
If Vault has never been initialised:  make vault-init
If the keys are elsewhere, restore them to $KEYS (mode 600)."

  st=$(vault_status_json)
  if [[ "$(printf '%s' "$st" | jbool .sealed)" == "false" ]]; then
    ok 'already unsealed, nothing to do'
    exit 0
  fi

  step "unsealing with $THRESHOLD of $SHARES keys"
  # Each key is submitted separately; Vault counts them until the threshold is met. Looping to
  # the threshold rather than over every key means the remaining shares are never transmitted,
  # which is the entire point of a threshold.
  for i in $(seq 0 $((THRESHOLD - 1))); do
    key=$(jq -r ".unseal_keys_b64[$i]" "$KEYS")
    [[ -n "$key" && "$key" != "null" ]] || die "unseal key $i missing from $KEYS"
    out=$(kubectl -n "$NS" exec -i "$POD" -- vault operator unseal -format=json "$key" 2>&1) \
      || die "unseal with key $i failed:
$out"
    sealed=$(printf '%s' "$out" | jbool .sealed)
    prog=$(printf '%s' "$out" | jq -r '.progress // "?"' 2>/dev/null || echo '?')
    printf '    key %s accepted (sealed=%s progress=%s)\n' "$((i + 1))" "$sealed" "$prog"
    [[ "$sealed" == "false" ]] && break
  done

  st=$(vault_status_json)
  if [[ "$(printf '%s' "$st" | jbool .sealed)" == "false" ]]; then
    ok "unsealed - Vault $(printf '%s' "$st" | jq -r '.version // "?"') is serving"
    echo
    printf '%s  This has to be done again after every cluster restart.%s That friction is the\n' "$c_dim" "$c_off"
    printf '  honest cost of holding the keys yourself; in a cloud it would be KMS auto-unseal,\n'
    printf '  which moves the secret rather than removing it (ADR-0018).\n'
  else
    die "still sealed after $THRESHOLD keys. Check the pod logs:
  kubectl -n $NS logs $POD --tail=30"
  fi
  ;;

*)
  die "usage: vault-ops.sh <status|init|unseal>"
  ;;
esac
