#!/usr/bin/env bash
# SOURCED, not run. Shared plumbing for talking to Vault from outside the cluster.
#
#   source scripts/vault-exec.lib.sh
#
# Two scripts need this - vault-bootstrap and eso-check - and the one thing worth factoring out
# is how the root token gets into the pod, because the obvious way is wrong.
#
# THE OBVIOUS WAY, AND WHY NOT:
#
#   kubectl exec vault-0 -- env VAULT_TOKEN="$tok" vault write ...
#
# That puts Vault's root token - the credential that can read and change every secret this
# platform will ever hold - into a command line. Command lines are visible in `ps`, and
# `kubectl exec` records its argv in the API server's audit log at Request level. So a token with
# no expiry ends up in a log file that is backed up and read by other people, and nothing about
# the command looks wrong.
#
# So the token travels on STDIN and is read into a shell variable inside the pod. The PROGRAM
# travels in argv, which is correct - a program is not a secret - and that split is the whole
# reason these helpers exist rather than being inlined.
#
# One subtlety that makes this safe: `read` on a pipe may buffer more than one line, which would
# normally eat whatever came next on stdin. Here nothing comes next - the token is the only thing
# written - so over-reading consumes EOF and nothing is lost. The one case that does depend on
# stdin continuing past the token is handled by a separate helper that sends no token at all.

# Guard against being run instead of sourced. ${BASH_SOURCE[0]} == $0 exactly when this file is
# the script being executed.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "vault-exec.lib.sh is a library - source it, do not run it:" >&2
  echo "    source scripts/vault-exec.lib.sh" >&2
  exit 1
fi

VAULT_NS="${VAULT_NS:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_KEYS="${VAULT_KEYS:-.cache/vault-init.json}"
VAULT_ROOT_TOKEN=""

# `vault status` exits 0 unsealed, 2 sealed, 1 on error, so a bare call under `set -e` aborts on
# the normal sealed state. The `|| true` is load-bearing (the same note is in vault-ops.sh).
vault_status_json() {
  kubectl -n "$VAULT_NS" exec "$VAULT_POD" -- vault status -format=json 2>/dev/null || true
}

# jq's `//` treats FALSE as empty, so `.sealed // "unknown"` returns "unknown" exactly when Vault
# is working. That bug shipped in four places in the first version of vault-ops.sh and would have
# made `make vault-unseal` report failure on every success. `tostring` has no such trap.
vault_jbool() { jq -r "${1} | tostring" 2>/dev/null || echo null; }

# Assert Vault is present, initialised and unsealed. Every caller needs this and every caller
# would otherwise write its own slightly different version.
vault_require_ready() {
  local st init sealed
  kubectl -n "$VAULT_NS" get pod "$VAULT_POD" >/dev/null 2>&1 || {
    echo "$VAULT_NS/$VAULT_POD does not exist. Argo CD may not have synced Vault:" >&2
    echo "    make gitops-refresh && make gitops-status" >&2
    return 1
  }
  st=$(vault_status_json)
  [[ -n "$st" ]] || { echo "$VAULT_POD is not answering - kubectl -n $VAULT_NS logs $VAULT_POD --tail=30" >&2; return 1; }
  init=$(printf '%s' "$st" | vault_jbool .initialized)
  sealed=$(printf '%s' "$st" | vault_jbool .sealed)
  [[ "$init" == "true" ]]   || { echo "Vault is not initialised - run: make vault-init" >&2; return 1; }
  [[ "$sealed" == "false" ]] || { echo "Vault is SEALED - run: make vault-unseal" >&2; return 1; }
  return 0
}

# Load the root token into a shell variable. Never echoed, never exported into a child's
# environment that a `ps` could read, never written anywhere.
vault_load_root_token() {
  [[ -f "$VAULT_KEYS" ]] || {
    echo "$VAULT_KEYS not found - Vault's root token lives only there (ADR-0018 Decision 3)." >&2
    echo "If Vault has never been initialised:  make vault-init" >&2
    return 1
  }
  VAULT_ROOT_TOKEN=$(jq -r '.root_token // ""' "$VAULT_KEYS")
  [[ -n "$VAULT_ROOT_TOKEN" && "$VAULT_ROOT_TOKEN" != "null" ]] || {
    echo "$VAULT_KEYS has no .root_token - it is not the file vault operator init wrote." >&2
    return 1
  }
  return 0
}

# Run a shell program inside the Vault pod with VAULT_TOKEN set to the root token.
#
#   vsh 'vault secrets list -format=json'
#   vsh 'vault write auth/kubernetes/role/"$1" ...' "$role"
#
# Extra arguments become $1, $2 ... inside the program, which is how a value reaches it without
# being spliced into the program text. Splicing is how a quote in a value becomes a shell
# injection, and these values come from cluster objects rather than from this file.
vsh() {
  local prog=$1; shift
  printf '%s\n' "$VAULT_ROOT_TOKEN" \
    | kubectl -n "$VAULT_NS" exec -i "$VAULT_POD" -- sh -c '
        read -r VAULT_TOKEN
        export VAULT_TOKEN
        PROG=$1; shift
        eval "$PROG"' sh "$prog" "$@"
}

# Run a shell program inside the Vault pod with NO token, passing this function's stdin through
# untouched. For the one case where the program supplies its own credential: logging in as
# somebody else to check that the login works.
vsh_unauth() {
  local prog=$1; shift
  kubectl -n "$VAULT_NS" exec -i "$VAULT_POD" -- sh -c '
        PROG=$1; shift
        eval "$PROG"' sh "$prog" "$@"
}
