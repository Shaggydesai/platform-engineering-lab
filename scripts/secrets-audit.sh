#!/usr/bin/env bash
# Is any live credential findable in this repository - in the working tree or anywhere in history?
#
#   make secrets-audit
#
# The roadmap's bar for Module 07 is "git grep finds no credential". That is a claim about this
# repository, so it should be answered BY this repository rather than by someone remembering to
# look - and answered against the values that are actually live, not against a list of things
# somebody thought to check.
#
# So it reads the real secrets out of the cluster and out of .cache/vault-init.json, and searches
# every commit on every ref for each one.
#
# WHAT IT CHECKS, and the second group matters more than the first:
#
#   the tenant's six credentials      a leak here exposes one application
#   Vault's root token and unseal keys  a leak here exposes EVERY secret this platform will
#                                       ever hold, and no rotation undoes a key that is in Git
#                                       history on someone else's clone
#
# The values never reach a command line: `git grep -f` reads its patterns from a file, written
# with umask 077 into .cache (which is gitignored) and shredded afterwards. `git grep -e "$v"`
# would put each credential in a process argument.
#
# It never prints a value, including when it finds one. A finding reports the KEY NAME and the
# rev:path, which is everything needed to act and nothing extra. `git grep` without --name-only
# would print the matching line, i.e. the secret, into a terminal and a scrollback buffer.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP=gitops/clusters/onprem/apps/shopverse.yaml
KEYS_FILE=.cache/vault-init.json
PATTERNS=.cache/.secrets-audit-patterns
PATTERNS_ID=.cache/.secrets-audit-identifiers

# Two of the six keys hold IDENTIFIERS, not credentials, and both are in Git on purpose: the
# `shopverse-secret` target in the Makefile sets `admin-email=admin@shopverse.local` and
# `mongo-username=shopverse` as literals. They are the "who", not the "proof".
#
# This list exists because the first version of this script did not have it, and the first test
# run reported "a live credential is in this repository - treat it as disclosed" for an email
# address, pointing at the Makefile across 97 commits. A check that cries leak over a username is
# a check nobody reads the output of after the second time - which is worse than not having it,
# because the next alert is real.
#
# They are still searched for, and a match is still reported. It is reported as what it is.
IDENTIFIER_KEYS=(admin-email mongo-username)

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
same() { printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; }
warn() { printf '    %s%s%s\n' "$c_warn" "$*" "$c_off"; }
bad()  { printf '    %s%s%s\n' "$c_err" "$*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

command -v jq >/dev/null || die "jq not installed - run: make tools"
command -v yq >/dev/null || die "yq not installed - run: make tools"

cleanup() {
  for f in "$PATTERNS" "$PATTERNS_ID"; do
    [[ -f "$f" ]] || continue
    command -v shred >/dev/null && shred -u "$f" 2>/dev/null || rm -f "$f"
  done
}
trap cleanup EXIT

printf '%sSecrets audit: is any live credential in this repository?%s\n\n' "$c_step" "$c_off"

# ---------------------------------------------------------------- 0  gather what to look for
step 'collecting the values to search for'
umask 077
: > "$PATTERNS"
: > "$PATTERNS_ID"

n_secret=0; n_ident=0; n_skipped=0
add_pattern() { # $1 = label, $2 = value, $3 = key name (to classify it)
  [[ -n "${2:-}" && "$2" != "null" ]] || return 0
  # A very short value would match half the repository and mean nothing. 12 is arbitrary and
  # generous: every credential `make shopverse-secret` generates is 48 hex characters.
  if (( ${#2} < 12 )); then
    same "skipping $1 - only ${#2} characters, too short to search for meaningfully"
    n_skipped=$((n_skipped + 1))
    return 0
  fi
  for ik in "${IDENTIFIER_KEYS[@]}"; do
    if [[ "${3:-}" == "$ik" ]]; then
      printf '%s\n' "$2" >> "$PATTERNS_ID"
      n_ident=$((n_ident + 1))
      return 0
    fi
  done
  printf '%s\n' "$2" >> "$PATTERNS"
  n_secret=$((n_secret + 1))
}
if NS=$(yq -r '.spec.destination.namespace' "$APP" 2>/dev/null) && [[ -n "$NS" && "$NS" != "null" ]]; then
  # Both names, because both may exist during and after the migration: the ExternalSecret-managed
  # one and the hand-made one kept for rollback. A credential leaking from the retired Secret is
  # still a leaked credential.
  for sname in shopverse-secrets shopverse-credentials; do
    sjson=$(kubectl -n "$NS" get secret "$sname" -o json 2>/dev/null) || continue
    found_secret=1
    while IFS= read -r k; do
      add_pattern "$sname/$k" "$(printf '%s' "$sjson" | jq -r --arg k "$k" '.data[$k]' | base64 -d)" "$k"
    done < <(printf '%s' "$sjson" | jq -r '.data | keys_unsorted[]')
  done
  # Counted from what was actually ADDED, not from what was iterated over. The first version
  # incremented per key and then reported "12 tenant credential(s)" when ten had been skipped as
  # too short - a check over-reporting its own coverage, which is the same sin as the summary
  # that claimed a NetworkPolicy had been verified when none existed.
  if (( ${found_secret:-0} == 1 )); then
    ok "$n_secret credential(s) and $n_ident identifier(s) from $NS"
    (( n_skipped > 0 )) && same "$n_skipped value(s) skipped as too short - they are NOT covered"
  else
    warn "no tenant Secret found in $NS - the tenant half is UNCHECKED"
  fi
else
  warn "could not read a namespace from $APP - the tenant half is UNCHECKED"
fi

n_vault=0
if [[ -r "$KEYS_FILE" ]]; then
  before=$n_secret
  add_pattern "vault/root-token" "$(jq -r '.root_token // ""' "$KEYS_FILE")" root-token
  while IFS= read -r key; do
    add_pattern "vault/unseal-key" "$key" unseal-key
  done < <(jq -r '.unseal_keys_b64[]? // empty' "$KEYS_FILE")
  n_vault=$((n_secret - before))
  ok "$n_vault Vault key(s) from $KEYS_FILE"
else
  warn "$KEYS_FILE not readable - Vault's root token and unseal keys are UNCHECKED"
  warn 'That is the half that matters most: a leaked unseal key cannot be rotated out of'
  warn "someone else's clone."
fi

n=$(wc -l < "$PATTERNS" | tr -d ' ')
(( n > 0 )) || die "no CREDENTIALS to search for. This is not a pass - it is a check that did not
run. Is the cluster reachable, and has Vault been initialised?"
same "$n credential(s) and $n_ident identifier(s) written to .cache (mode 600, shredded on exit)"

# The keys file itself must be ignored, or the next `git add -A` commits the unseal keys. Cheap to
# assert, catastrophic to get wrong, and exactly the kind of thing a .gitignore edit breaks
# silently.
if [[ -e "$KEYS_FILE" ]]; then
  if git check-ignore -q "$KEYS_FILE"; then
    ok "$KEYS_FILE is gitignored"
  else
    bad "$KEYS_FILE is NOT gitignored"
    die "The only copy of every unseal key is one `git add -A` away from being committed.
Fix .gitignore before doing anything else."
  fi
fi

# ---------------------------------------------------------------- 1  the working tree
step 'the working tree (tracked files)'
tree_fail=0
if hits=$(git grep -I --name-only -F -f "$PATTERNS" -- . 2>/dev/null); then
  bad 'a live CREDENTIAL is present in a tracked file:'
  printf '%s\n' "$hits" | sed 's/^/      /'
  tree_fail=1
else
  ok 'no credential in any tracked file'
fi
# Identifiers are expected in Git - the Makefile sets two of them as literals - so a match is
# reported and is not a failure. Reporting it anyway matters: if `admin-email` ever stops being an
# email and starts being something that matters, this line is where it shows up.
if ihits=$(git grep -I --name-only -F -f "$PATTERNS_ID" -- . 2>/dev/null); then
  same "identifiers (not credentials) appear in: $(printf '%s' "$ihits" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- 2  all of history
step 'every commit on every ref'
# This is the question that matters. A credential removed in a later commit is still in history,
# still in every clone, and still readable by anyone who has ever fetched this repository -
# "we took it out" is not a remedy.
revs=$(git rev-list --all | wc -l | tr -d ' ')
same "searching $revs commit(s)"
hist_fail=0
if hist=$(git grep -I --name-only -F -f "$PATTERNS" $(git rev-list --all) -- 2>/dev/null); then
  bad 'a live CREDENTIAL appears in history:'
  printf '%s\n' "$hist" | sort -u | head -20 | sed 's/^/      /'
  hist_fail=1
else
  ok "no credential in any of $revs commits"
fi

# ---------------------------------------------------------------- the verdict
echo
if (( tree_fail == 0 && hist_fail == 0 )); then
  printf '%sno live credential is findable in this repository%s\n\n' "$c_ok" "$c_off"
  printf 'Checked %d credential(s) against %d commits: the tenant'"'"'s secrets and Vault'"'"'s root\n' "$n" "$revs"
  printf 'token and unseal keys. That is the roadmap'"'"'s "git grep finds no credential" bar,\n'
  printf 'answered by searching for the values that are actually live.\n\n'
  printf '%s%d identifier(s)%s - admin-email, mongo-username - were searched for separately and\n' "$c_dim" "$n_ident" "$c_off"
  printf 'are expected in Git: the Makefile sets them as literals. They are the "who", not the\n'
  printf '"proof", and treating them as leaks is how a check stops being read.\n\n'
  printf '%sWhat this does NOT check:%s untracked files in this working copy (%s is one,\n' "$c_dim" "$c_off" "$KEYS_FILE"
  printf 'deliberately - ADR-0018 Decision 3), your shell history, or any other clone. It also\n'
  printf 'cannot find a credential that is no longer live: a value rotated out of the cluster but\n'
  printf 'still sitting in commit 40 is invisible to this check, because the cluster is where it\n'
  printf 'learns what to look for.\n'
  exit 0
fi

printf '%sa live credential is in this repository%s\n\n' "$c_err" "$c_off"
printf 'Treat it as disclosed. It is in every clone and every fork, and removing it in a new\n'
printf 'commit does not remove it from history.\n\n'
printf '  1. ROTATE the value first - see docs/runbooks/07-secrets.md. Until it is rotated,\n'
printf '     rewriting history only makes the leak harder to find.\n'
printf '  2. Then decide about history: git-filter-repo rewrites every commit, which breaks\n'
printf '     every existing clone and does nothing about copies already fetched.\n'
printf '  3. If it is a Vault unseal key, rotation means `vault operator rekey` - and the old\n'
printf '     keys keep working until that completes.\n'
exit 1
