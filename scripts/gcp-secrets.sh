#!/usr/bin/env bash
# ShopVerse's credentials in GCP Secret Manager.
#
#   make gcp-secrets-seed      generate the six values and add them as a version
#   make gcp-secrets-verify    read it back: a version exists, parses, holds the right six keys
#
# ONE SCRIPT, TWO SUBCOMMANDS, and the reason is the six key names. They are not ours - they come
# from ShopVerse's own chart, which renders one ExternalSecret entry per name in a hardcoded list
# (helm/shopverse/templates/externalsecret.yaml, in the application's repository). A name that
# disagrees with that list produces an ExternalSecret stuck on a property that does not exist, and
# the error names the property rather than the mismatch. Defining the list in two scripts is how
# the two come to disagree, so there is one script.
#
# WHAT NEVER HAPPENS IN HERE, carried over from Module 07 and for the same reasons:
#
#   no value is ever passed in a shell ARGUMENT. argv is visible to `ps` for every user on the
#   machine, and on the cluster side it is recorded in the API server's audit log.
#
#   no value is ever written to DISK. The payload is assembled in a variable and streamed to
#   gcloud on stdin. There is no temp file to forget to delete and no file mode to get wrong -
#   which is the mistake that left /etc/kubernetes/enc/key1.b64 world-readable on-prem until
#   something ran the tasks and looked.
#
#   no value is ever PRINTED. Verification compares SHA-256 hashes and reports key names.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CFG=clusters/gcp/cluster.json
TF_DIR=terraform/gcp/secrets

# THE SIX KEYS, in the order ShopVerse's chart lists them. The order does not matter to anything;
# the SET does, exactly.
KEYS=(jwt-secret internal-token admin-email admin-password mongo-username mongo-password)

# The two that are identifiers rather than secrets, and are therefore fixed rather than generated.
#
# `scripts/secrets-audit.sh` already makes this distinction for the on-prem values and classifies
# findings on them separately, because admin@shopverse.local appears in the Makefile by design.
# Generating them would be worse than pointless: admin-email is what a human types to log in, and
# mongo-username is embedded in the connection string.
ADMIN_EMAIL=admin@shopverse.local
MONGO_USERNAME=shopverse

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s[ ok ]%s %s\n' "$c_ok" "$c_off" "$*"; }
bad()  { printf '    %s[fail]%s %s\n' "$c_err" "$c_off" "$*"; }
warn() { printf '    %s[warn]%s %s\n' "$c_warn" "$c_off" "$*"; }
note() { printf '           %s%s%s\n' "$c_dim" "$*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

command -v jq >/dev/null     || die "jq not installed - run: make tools"
command -v gcloud >/dev/null || die "gcloud not installed - see docs/runbooks/01-onprem-vms.md"

PROJECT=$(jq -r '.project_id' "$CFG")
[[ -n "$PROJECT" && "$PROJECT" != "null" ]] || die "project_id is empty in $CFG"

# The secret ID comes from Terraform's locals, which is also where the overlay's checked value
# comes from - read rather than repeated, so this cannot name a secret the overlay does not.
SECRET_ID=$(grep -E '^\s*secret_id\s*=' "$TF_DIR/variables.tf" | head -1 | sed 's/.*"\(.*\)".*/\1/')
[[ -n "$SECRET_ID" ]] || die "could not read secret_id from $TF_DIR/variables.tf"

G=(gcloud --project="$PROJECT" --quiet)

# ---------------------------------------------------------------------------- helpers
# URL-SAFE RANDOMNESS, and this is a correctness requirement rather than a preference.
#
# ShopVerse's own values.yaml says of mongoPassword: "Must be URL-safe (it is embedded in the
# Mongo connection string)". A password containing + or / or @ - all of which plain base64 and
# most password generators produce - produces a connection string that parses as a different host,
# and the failure is an authentication error against a database that is up and healthy.
#
# So: base64, then the two offending characters removed, then truncated. Taking more bytes than
# needed first means the result is still full length after the removals.
rand() {
  local want=${1:-32}
  LC_ALL=C tr -dc 'A-Za-z0-9_-' < /dev/urandom | head -c "$want"
}

# Hash a value without ever printing it. Reads stdin, strips trailing newlines the way the Vault
# seeding script had to (`vault kv get -field` adds one, and all six values compared as DIFFERENT
# until both sides were normalised the same way).
h() { printf '%s' "$(cat)" | sha256sum | cut -d' ' -f1; }

secret_exists() {
  "${G[@]}" secrets describe "$SECRET_ID" >/dev/null 2>&1
}

version_count() {
  "${G[@]}" secrets versions list "$SECRET_ID" --filter='state:ENABLED' \
    --format='value(name)' 2>/dev/null | grep -c . || true
}

require_secret() {
  if ! secret_exists; then
    die "no Secret Manager secret named '$SECRET_ID' in $PROJECT

The container is created by Terraform, not by this script - Terraform owns the SHAPE and
this script owns the CONTENT, so that no secret value is ever written into a state file:

  make gcp-secrets"
  fi
}

# ---------------------------------------------------------------------------- seed
cmd_seed() {
  printf '%sSeeding ShopVerse credentials into Secret Manager%s\n' "$c_step" "$c_off"
  printf '  project %s   secret %s\n' "$PROJECT" "$SECRET_ID"
  require_secret

  step 'is there already a version?'
  local n
  n=$(version_count)
  if [[ "$n" != "0" ]]; then
    bad "$SECRET_ID already has $n enabled version(s) - refusing to add another"
    printf '\n'
    printf '  %sTHIS IS NOT A SAFETY RAIL ABOUT TIDINESS.%s Adding a version changes\n' "$c_err" "$c_off"
    printf '  mongo-password, and MongoDB only reads that value once - when it initialises its\n'
    printf '  root user on first boot. A database already initialised with the previous value\n'
    printf '  will come up Running and Ready and refuse every connection, which is precisely\n'
    printf '  the failure Module 07 spent a day avoiding on-prem (ADR-0018 Decision 5).\n\n'
    printf '  So a reseed is only correct together with destroying the database volume:\n'
    printf '    make gcp-down                       # takes the cluster and its PVs with it\n'
    printf '    gcloud secrets versions destroy 1 --secret=%s --project=%s\n' "$SECRET_ID" "$PROJECT"
    printf '    make gcp-secrets-seed\n\n'
    printf '  And mind the free tier: six enabled versions per month are free, the seventh is a\n'
    printf '  standing charge, which ADR-0003 forbids however small. DESTROY the old version\n'
    printf '  rather than leaving it - disabling is not enough, a disabled version still counts.\n'
    exit 1
  fi
  ok 'no versions yet, so nothing can be overwritten'

  step 'generating six values'
  # FRESH, not copied from the on-prem Vault, and the decision is deliberate.
  #
  # ADR-0018's portability claim is about the MANIFEST, not the values - nothing requires the two
  # substrates to share credentials, and sharing them would mean a compromise on the laptop is a
  # compromise in the cloud. On-prem had to copy rather than regenerate for one specific reason
  # that does not apply here: mongo-password had already initialised a database on a volume that
  # was being kept. GKE's MongoDB will be a fresh PersistentVolume on a cluster that does not
  # exist yet, so there is nothing to stay byte-identical with.
  local jwt internal admin_pw mongo_pw payload
  jwt=$(rand 48)
  internal=$(rand 48)
  admin_pw=$(rand 24)
  mongo_pw=$(rand 32)

  for v in "$jwt" "$internal" "$admin_pw" "$mongo_pw"; do
    [[ -n "$v" ]] || die 'generated an empty value - /dev/urandom or tr is behaving unexpectedly'
  done
  ok "4 generated, 2 fixed identifiers (admin-email, mongo-username)"
  note 'all generated values use [A-Za-z0-9_-] only: mongo-password is embedded in a'
  note 'connection string, and a + or / in it parses as a different host'

  # jq --arg, so no value is ever interpolated into a shell string that could be re-split, and
  # jq does the JSON escaping rather than this script guessing at it.
  payload=$(jq -nc \
    --arg jwt "$jwt" \
    --arg internal "$internal" \
    --arg email "$ADMIN_EMAIL" \
    --arg adminpw "$admin_pw" \
    --arg mongouser "$MONGO_USERNAME" \
    --arg mongopw "$mongo_pw" \
    '{"jwt-secret":$jwt,"internal-token":$internal,"admin-email":$email,
      "admin-password":$adminpw,"mongo-username":$mongouser,"mongo-password":$mongopw}')

  step 'the payload has exactly the six keys the tenant asks for'
  local got want
  got=$(printf '%s' "$payload" | jq -r 'keys_unsorted | sort | join(",")')
  want=$(printf '%s\n' "${KEYS[@]}" | sort | paste -sd,)
  if [[ "$got" == "$want" ]]; then
    ok "$got"
  else
    die "payload keys are [$got], the chart asks for [$want]"
  fi

  step 'adding the version, on stdin'
  # --data-file=- is stdin. NOT --data-file with a path, and emphatically not a flag carrying the
  # value: `gcloud secrets versions add X --data=...` does exist and would put all six credentials
  # in this process's argv, readable by `ps` for as long as the call takes.
  #
  # printf rather than echo, and no trailing newline: Secret Manager stores the bytes exactly as
  # given, so a trailing newline becomes part of the payload. JSON parses either way, so this
  # would not break - it would just make every hash comparison against a freshly built payload
  # disagree, which is the shape of the bug that made all six Vault values report DIFFERENT.
  if ! out=$(printf '%s' "$payload" | "${G[@]}" secrets versions add "$SECRET_ID" --data-file=- 2>&1); then
    die "could not add the version:
$(printf '%s' "$out" | head -3)"
  fi
  ok "version added"

  step 'reading it straight back out'
  # The point of Module 07's seeding script, repeated: a write that the API accepted is not a
  # value that can be read. Compared by HASH, so nothing is printed either way.
  local readback
  readback=$("${G[@]}" secrets versions access latest --secret="$SECRET_ID" 2>/dev/null)
  local fails=0
  for k in "${KEYS[@]}"; do
    local a b
    a=$(printf '%s' "$payload"  | jq -r --arg k "$k" '.[$k]' | h)
    b=$(printf '%s' "$readback" | jq -r --arg k "$k" '.[$k]' | h)
    if [[ "$a" == "$b" && -n "$a" ]]; then
      ok "$k  matches  ${a:0:12}"
    else
      bad "$k  DIFFERS"
      fails=$((fails + 1))
    fi
  done
  (( fails == 0 )) || die "$fails value(s) did not survive the round trip"

  printf '\n%sall six values are in Secret Manager and read back identical%s\n\n' "$c_ok" "$c_off"
  printf 'There is now NO OTHER COPY of these values anywhere - not in Git, not in Terraform\n'
  printf 'state, not on this disk. That is the design, and it is a different risk profile from\n'
  printf 'on-prem rather than a smaller one:\n\n'
  printf '  .cache/vault-init.json      losing it makes every Vault secret UNRECOVERABLE\n'
  printf '  Secret Manager              losing it costs a reseed and a fresh database\n\n'
  printf 'The second is recoverable because the values are not protecting anything that outlives\n'
  printf 'the cluster. The moment something on GKE holds data worth keeping, re-read that line.\n\n'
  printf 'Next:\n'
  printf '  make gcp-secrets-verify\n'
}

# ---------------------------------------------------------------------------- verify
cmd_verify() {
  printf '%sIs the GCP secret backend actually usable?%s\n' "$c_step" "$c_off"
  printf '  project %s   secret %s\n' "$PROJECT" "$SECRET_ID"

  local fails=0

  step 'the secret exists'
  if secret_exists; then
    ok "$SECRET_ID"
  else
    bad "no secret named $SECRET_ID - run: make gcp-secrets"
    exit 1
  fi

  step 'the service account External Secrets acts as'
  local gsa
  gsa="external-secrets@${PROJECT}.iam.gserviceaccount.com"
  if "${G[@]}" iam service-accounts describe "$gsa" >/dev/null 2>&1; then
    ok "$gsa"
  else
    bad "$gsa does not exist - run: make gcp-secrets"
    fails=$((fails + 1))
  fi

  step 'and may it read this secret, specifically?'
  # THE GRANT, read back off the secret rather than off the project. A project-wide
  # secretAccessor would also make the ExternalSecret work, and would mean External Secrets can
  # read every secret in the project - so "it works" is not the question being asked here.
  local members
  members=$("${G[@]}" secrets get-iam-policy "$SECRET_ID" --format=json 2>/dev/null \
            | jq -r '[.bindings[]? | select(.role=="roles/secretmanager.secretAccessor") | .members[]?] | join(" ")')
  if [[ " $members " == *" serviceAccount:$gsa "* ]]; then
    ok 'secretAccessor, bound on the SECRET and not on the project'
    note 'the GCP analogue of the Vault policy scoped to secret/data/shopverse/*'
  else
    bad 'no secretAccessor binding for that account on this secret'
    note "bound instead: ${members:-(nothing)}"
    fails=$((fails + 1))
  fi

  step 'may the Kubernetes service account become it?'
  local wi want_member
  want_member="serviceAccount:${PROJECT}.svc.id.goog[external-secrets/external-secrets]"
  wi=$("${G[@]}" iam service-accounts get-iam-policy "$gsa" --format=json 2>/dev/null \
       | jq -r '[.bindings[]? | select(.role=="roles/iam.workloadIdentityUser") | .members[]?] | join(" ")')
  if [[ " $wi " == *" $want_member "* ]]; then
    ok 'workloadIdentityUser for external-secrets/external-secrets'
    note 'this is what replaces a downloaded JSON key file - there is no key for this account'
  else
    bad 'no workloadIdentityUser binding for the external-secrets service account'
    note "wanted: $want_member"
    note "bound:  ${wi:-(nothing)}"
    note 'IAM accepts any syntactically valid principal, including one naming a service account'
    note 'that does not exist - so this fails in the pod as a 403, not at apply time'
    fails=$((fails + 1))
  fi

  step 'is there a payload, and is it the right shape?'
  local n
  n=$(version_count)
  if [[ "$n" == "0" ]]; then
    bad 'the secret has no enabled version - an ExternalSecret against it cannot resolve'
    note 'make gcp-secrets-seed'
    fails=$((fails + 1))
  else
    # Reported by the cost check further down rather than here, because "ok: 7 enabled versions"
    # printed directly above "fail: 7 enabled versions, this is now billing" is a self-
    # contradicting pair of lines, and output that argues with itself is output nobody trusts.
    note "$n enabled version(s)"
    local payload
    if ! payload=$("${G[@]}" secrets versions access latest --secret="$SECRET_ID" 2>/dev/null); then
      bad 'could not read the latest version'
      fails=$((fails + 1))
    elif ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
      # The gcpsm provider JSON-parses the payload to resolve `property`. A payload that is not
      # JSON makes every one of the six lookups fail, and the error talks about the property.
      bad 'the payload is not valid JSON - every `property` lookup would fail'
      fails=$((fails + 1))
    else
      local got want
      got=$(printf '%s' "$payload" | jq -r 'keys_unsorted | sort | join(",")')
      want=$(printf '%s\n' "${KEYS[@]}" | sort | paste -sd,)
      if [[ "$got" == "$want" ]]; then
        ok "exactly the six keys the tenant's chart asks for"
        # Key names and short hashes only. Never values.
        for k in "${KEYS[@]}"; do
          printf '           %s%-16s %s%s\n' "$c_dim" "$k" \
            "$(printf '%s' "$payload" | jq -r --arg k "$k" '.[$k]' | h | cut -c1-12)" "$c_off"
        done
      else
        bad "keys are [$got]"
        note "the chart asks for [$want]"
        fails=$((fails + 1))
      fi
    fi

    # The cost line, and it is the one thing here that is a standing charge rather than a
    # one-off. ADR-0003 forbids a standing charge however small, so this is a failure at seven
    # rather than a note.
    if (( n > 6 )); then
      bad "$n enabled versions - Secret Manager gives SIX free, so this is now billing"
      note 'destroy the old ones (disabling is not enough, a disabled version still counts):'
      note "  gcloud secrets versions destroy N --secret=$SECRET_ID --project=$PROJECT"
      fails=$((fails + 1))
    elif (( n > 1 )); then
      warn "$n of the 6 free versions used"
      note 'each reseed adds one. Destroy versions you no longer need before the seventh.'
    else
      ok "$n enabled version, of the 6 Secret Manager gives free"
    fi
  fi

  printf '\n'
  if (( fails )); then
    die "$fails check(s) failed"
  fi
  printf '%sthe backend is ready%s\n\n' "$c_ok" "$c_off"
  printf 'What this still cannot tell you: %swhether External Secrets can actually read it%s.\n' "$c_warn" "$c_off"
  printf 'Every check above was made as YOU, with your own credentials. The thing that matters is\n'
  printf 'whether a pod holding a Kubernetes service account token can exchange it for this\n'
  printf 'account and get the payload - and only a running cluster can answer that.\n\n'
  printf '  make gcp-up && make gcp-kubeconfig && make gcp-argocd\n'
  printf '  make gcp-smoke        checks the ClusterSecretStore reports Ready\n'
}

case "${1:-}" in
  seed)   cmd_seed ;;
  verify) cmd_verify ;;
  *) die "usage: $0 seed|verify
  seed    generate the six values and add them as a version (refuses if one exists)
  verify  read the whole arrangement back out of the API" ;;
esac
