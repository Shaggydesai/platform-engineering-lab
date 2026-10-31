#!/usr/bin/env bash
# Does the ₹400 guardrail actually exist on the billing account, with the amount and the
# thresholds this repository asks for?
#
#   make gcp-guardrails-verify
#
# Terraform succeeding means the API accepted a request. This asks the API what it HAS.
#
# The first version of this check was worse than useless and it is worth saying how, because it
# passed: it listed every budget on the account and reported "budget(s) on the billing account".
# Against a real account that printed three - two pre-existing ₹2500 ones and ours - and called it
# success. Had the ₹400 guardrail failed to create, the other two would still have been there and
# the check would still have passed. It confirmed that SOMETHING was watching, which is not the
# question; the question is whether the thing this repository created is watching, at the amount
# ADR-0003 chose.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CFG=clusters/gcp/cluster.json
PREFIX="platform-engineering-lab guardrail"

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
same() { printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; }
warn() { printf '    %s%s%s\n' "$c_warn" "$*" "$c_off"; }
bad()  { printf '    %s%s%s\n' "$c_err" "$*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

command -v jq >/dev/null || die "jq not installed - run: make tools"
B="${TF_VAR_billing_account:-}"
[[ -n "$B" ]] || die "TF_VAR_billing_account is not set - see: make gcp-guardrails"

want_amount=$(jq -r '.budget.amount_inr' "$CFG")
want_currency=$(jq -r '.budget.currency' "$CFG")
want_thresholds=$(jq -rc '.budget.thresholds | sort' "$CFG")

printf '%sIs the guardrail ADR-0003 requires actually there?%s\n\n' "$c_step" "$c_off"

step "asking the API about billing account $B"
if ! raw=$(gcloud billing budgets list --billing-account="$B" --format=json 2>&1); then
  warn 'could not list budgets - verification UNKNOWN, not failed'
  printf '      %s%s%s\n' "$c_dim" "$(printf '%s' "$raw" | head -1)" "$c_off"
  printf '\n  A gcloud too old for `billing budgets`, or missing permission. The console is the\n'
  printf '  authority either way, and this is the one thing it must show:\n'
  printf '    https://console.cloud.google.com/billing/%s/budgets\n' "$B"
  # UNKNOWN is not a pass and not a failure. Exiting 0 here would let a cloud session start on
  # the strength of a check that could not run; exiting 1 would claim the guardrail is missing
  # when nothing was established. 2 is neither.
  exit 2
fi

n=$(printf '%s' "$raw" | jq 'length')
ok "$n budget(s) exist on the account"

# ---------------------------------------------------------------- ours, specifically
step "the one this repository creates"
ours=$(printf '%s' "$raw" | jq --arg p "$PREFIX" '[.[] | select(.displayName | startswith($p))]')
count=$(printf '%s' "$ours" | jq 'length')

if [[ "$count" == "0" ]]; then
  bad "NO budget whose name starts with \"$PREFIX\""
  printf '\n'
  printf '%s  Nothing this repository created is watching this account.%s Other budgets may exist\n' "$c_err" "$c_off"
  printf '  and they are not the same thing - they are not described by any file here, nobody\n'
  printf '  knows what amount they alert at, and no fresh clone would recreate them.\n\n'
  printf '  Do not create a cloud resource until this passes (ADR-0003 Decision 3):\n'
  printf '    make gcp-guardrails\n'
  exit 1
fi
[[ "$count" == "1" ]] || warn "$count budgets match that prefix - expected 1"

got_amount=$(printf '%s' "$ours" | jq -r '.[0].amount.specifiedAmount.units // ""')
got_currency=$(printf '%s' "$ours" | jq -r '.[0].amount.specifiedAmount.currencyCode // ""')
got_name=$(printf '%s' "$ours" | jq -r '.[0].displayName')
ok "found: $got_name"

fail=0
if [[ "$got_amount" == "$want_amount" && "$got_currency" == "$want_currency" ]]; then
  ok "amount $got_currency $got_amount matches $CFG"
else
  bad "amount is $got_currency $got_amount, $CFG says $want_currency $want_amount"
  fail=1
fi

# The thresholds are the guardrail. A budget with the right amount and no threshold rules alerts
# at nothing at all, and looks identical in a list.
got_thresholds=$(printf '%s' "$ours" | jq -c '[.[0].thresholdRules[]?.thresholdPercent] | sort')
if [[ "$got_thresholds" == "null" || "$got_thresholds" == "[]" ]]; then
  bad 'NO threshold rules - this budget alerts at nothing'
  printf '      %sA budget with no thresholds is a line in a console and not a guardrail.%s\n' "$c_dim" "$c_off"
  fail=1
# Compared as NUMBERS by jq, not as strings by bash, and the difference is not academic: the
# first version did `[[ "$got" == "$want" ]]` and failed against a perfectly correct budget,
# because cluster.json writes 1.0 and jq preserves that literal while the API returns 1.
# `[0.5,0.9,1]` != `[0.5,0.9,1.0]` as text and is the same set of thresholds in every sense that
# matters. A check that fails on formatting sends someone to "fix" something that is right, which
# is worse than one that does not run - it spends trust as well as time.
elif [[ "$(jq -n --argjson a "$got_thresholds" --argjson b "$want_thresholds" '$a == $b')" == "true" ]]; then
  ok "thresholds $got_thresholds match $CFG"
else
  bad "thresholds are $got_thresholds, $CFG says $want_thresholds"
  fail=1
fi

# ---------------------------------------------------------------- everything else on the account
others=$(printf '%s' "$raw" | jq -r --arg p "$PREFIX" \
  '.[] | select(.displayName | startswith($p) | not)
   | "      " + .displayName + "   " + (.amount.specifiedAmount.currencyCode // "?")
     + " " + (.amount.specifiedAmount.units // "?")')
if [[ -n "$others" ]]; then
  echo
  step 'other budgets on this account, which nothing here manages'
  printf '%s\n' "$others"
  printf '\n    %sNot a failure, and worth a look once.%s A budget named "(terraform)" implies a state\n' "$c_warn" "$c_off"
  printf '    file somewhere that may no longer exist - and if that state created a budget, it may\n'
  printf '    have created other things too. `make cost-check` is what answers that.\n'
fi

echo
if (( fail )); then
  die "the guardrail exists but does not match what this repository asks for.
Re-apply it rather than editing it in the console, or the two disagree again tomorrow:
  make gcp-guardrails"
fi

printf '%sthe guardrail is present and matches %s%s\n\n' "$c_ok" "$CFG" "$c_off"
printf 'What this still cannot tell you: %swhether the email arrives%s. Cloud Billing sends budget\n' "$c_warn" "$c_off"
printf 'alerts to the billing account admins by default, and "admins" is an assumption about an\n'
printf 'address until a message lands in it. One look, once:\n'
printf '  https://console.cloud.google.com/billing/%s/budgets\n' "$B"
