#!/usr/bin/env bash
# Does the $5 guardrail actually exist on this AWS account, with the amount, the thresholds AND a
# subscriber this repository asks for?
#
#   make aws-guardrails-verify
#
# Terraform succeeding means the Budgets API accepted a request. This asks the API what it HAS.
#
# IT IS A PORT OF scripts/gcp-guardrails-verify.sh AND IT IS NOT A COPY, because the GCP version
# would pass on an AWS budget that cannot warn anybody. Three differences, and the third is the one
# with teeth:
#
#   1. The account ID comes from the API (`sts get-caller-identity`) rather than from a file a
#      human has to set. GCP needs the billing account ID because a budget attaches to a billing
#      account, which is not the project; an AWS budget attaches to the account the credentials
#      already belong to. So this script has no "I could not look because a variable is unset"
#      branch for the account - one less way to refuse a guardrail that is fine.
#
#   2. The thresholds are a SECOND API CALL. GCP returns thresholdRules inside the budget; AWS
#      keeps notifications in describe-notifications-for-budget. A budget with the right amount and
#      no notifications looks correct in `describe-budgets` and alerts at nothing.
#
#   3. SUBSCRIBERS ARE A THIRD CALL, AND AWS HAS NO DEFAULT RECIPIENT. Cloud Billing emails the
#      billing account's admins whether or not anyone configured a channel, which is why the GCP
#      script can end by saying "we cannot tell you whether the email arrives" and leave it there.
#      AWS notifies NOBODY unless a subscriber is attached, and a notification with an empty
#      subscriber list is accepted by the API and silent forever. That is not an unknown - it is a
#      readable fact, and a guardrail that cannot warn you is a failure rather than a caveat.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CFG=clusters/aws/cluster.json
NAME="platform-engineering-lab guardrail"

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
warn() { printf '    %s%s%s\n' "$c_warn" "$*" "$c_off"; }
bad()  { printf '    %s%s%s\n' "$c_err" "$*" "$c_off"; }
dim()  { printf '      %s%s%s\n' "$c_dim" "$*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

command -v jq >/dev/null || die "jq not installed - run: make tools"

# EXIT 2 MEANS "I COULD NOT LOOK", and it is a different answer from "it is missing".
#
# This distinction was learned the expensive way twice: `make gcp-up` once refused on a guardrail
# that was present and correct because a variable was absent from a terminal, and `eso-check` once
# reported a working store as broken because a permission question was asked in a form whose "no"
# did not mean no. A caller gating a billable cluster on this needs to tell the two apart.
if ! command -v aws >/dev/null 2>&1; then
  warn 'the AWS CLI is not installed, so the guardrail cannot be checked'
  dim 'this is UNKNOWN, not a failure - nothing was established either way'
  printf '\n  Install it and configure credentials, then re-run:\n'
  printf '    aws configure        # region: %s\n' "$(jq -r '.region' "$CFG")"
  exit 2
fi

if ! acct=$(aws sts get-caller-identity --query Account --output text 2>&1); then
  warn 'the AWS CLI has no working credentials, so the guardrail cannot be checked'
  dim "$(printf '%s' "$acct" | head -1)"
  printf '\n  UNKNOWN, not a failure. Configure credentials and re-run:\n'
  printf '    aws configure\n'
  exit 2
fi

want_amount=$(jq -r '.budget.amount_usd' "$CFG")
want_currency=$(jq -r '.budget.currency' "$CFG")
# cluster.json stores fractions because that is the shape the GCP API takes; AWS wants percent.
# Converted here rather than stored twice, so the two substrates cannot disagree about what "the
# 50% threshold" means.
want_thresholds=$(jq -c '[.budget.thresholds[] * 100] | sort' "$CFG")

printf '%sIs the guardrail ADR-0003 requires actually there?%s\n\n' "$c_step" "$c_off"

# The account is PRINTED rather than stored, which is the whole reason it is not in cluster.json:
# an account ID identifies a payment instrument, this repository is public, and the one reader who
# needs to confirm which account is being acted on is looking at this output.
step "asking the Budgets API about account $acct"

if ! raw=$(aws budgets describe-budgets --account-id "$acct" --output json 2>&1); then
  # NotFoundException is the API's way of saying "this account has no budgets at all", which is a
  # real answer - the guardrail is missing - rather than a failure to look. Everything else
  # (AccessDenied, throttling, a network error) is genuinely unknown.
  if printf '%s' "$raw" | grep -q 'NotFoundException'; then
    bad 'this account has NO budgets at all'
    printf '\n'
    printf '%s  Nothing is watching this account.%s Do not create a billable resource until this\n' "$c_err" "$c_off"
    printf '  passes (ADR-0003 Decision 3):\n'
    printf '    make aws-guardrails\n'
    exit 1
  fi
  warn 'could not list budgets - verification UNKNOWN, not failed'
  dim "$(printf '%s' "$raw" | head -1)"
  printf '\n  An AccessDenied here means the principal lacks budgets:ViewBudget, which is an IAM\n'
  printf '  problem rather than a missing guardrail. The console is the authority either way:\n'
  printf '    https://us-east-1.console.aws.amazon.com/billing/home#/budgets\n'
  exit 2
fi

n=$(printf '%s' "$raw" | jq '.Budgets | length')
ok "$n budget(s) exist on the account"

# ---------------------------------------------------------------- ours, specifically
#
# BY EXACT NAME, not by counting. The GCP version of this check originally listed every budget on
# the account and reported "3 budget(s) on the billing account" as success - which would have
# passed with our guardrail absent and two unrelated ones present. It confirmed that SOMETHING was
# watching, which is not the question.
step "the one this repository creates"
ours=$(printf '%s' "$raw" | jq --arg n "$NAME" '[.Budgets[] | select(.BudgetName == $n)]')
count=$(printf '%s' "$ours" | jq 'length')

if [[ "$count" == "0" ]]; then
  bad "NO budget named \"$NAME\""
  printf '\n'
  printf '%s  Nothing this repository created is watching this account.%s Other budgets may exist\n' "$c_err" "$c_off"
  printf '  and they are not the same thing - they are not described by any file here, nobody\n'
  printf '  knows what amount they alert at, and no fresh clone would recreate them.\n\n'
  printf '  Do not create a billable resource until this passes (ADR-0003 Decision 3):\n'
  printf '    make aws-guardrails\n'
  exit 1
fi

got_amount=$(printf '%s' "$ours" | jq -r '.[0].BudgetLimit.Amount // ""')
got_currency=$(printf '%s' "$ours" | jq -r '.[0].BudgetLimit.Unit // ""')
got_type=$(printf '%s' "$ours" | jq -r '.[0].BudgetType // ""')
got_period=$(printf '%s' "$ours" | jq -r '.[0].TimeUnit // ""')
ok "found: $(printf '%s' "$ours" | jq -r '.[0].BudgetName')"

fail=0

# NUMERICALLY, not as text, and this is a lesson rather than a preference. The GCP version of this
# comparison failed against a perfectly correct budget because cluster.json writes 1.0 and the API
# returned 1: `[0.5,0.9,1]` != `[0.5,0.9,1.0]` as strings and is the same set of thresholds in
# every sense that matters. AWS is worse for this - it returns "5.0" for a limit of 5 - so a string
# comparison here would fail on every correct apply.
if [[ "$got_currency" == "$want_currency" ]] \
   && [[ "$(jq -n --argjson a "${got_amount:-null}" --argjson b "$want_amount" '$a == $b' 2>/dev/null)" == "true" ]]; then
  ok "limit $got_currency $got_amount matches $CFG"
else
  bad "limit is $got_currency $got_amount, $CFG says $want_currency $want_amount"
  dim 'a budget denominated in a currency the account does not bill in is rejected rather than'
  dim 'converted, so a mismatch here can mean the account bills in something else entirely'
  fail=1
fi

[[ "$got_type" == "COST" ]] || { bad "budget type is $got_type, expected COST"; fail=1; }
[[ "$got_period" == "MONTHLY" ]] || { bad "period is $got_period, expected MONTHLY"; fail=1; }

# ---------------------------------------------------------------- the thresholds, a second call
#
# A budget with the right amount and no notifications alerts at nothing and looks identical in
# `describe-budgets`. On GCP the thresholds come back inside the budget; here they do not.
step 'the thresholds, which are a separate API object'
no_notif=0
unknown=0
if ! notif=$(aws budgets describe-notifications-for-budget \
               --account-id "$acct" --budget-name "$NAME" --output json 2>&1); then
  if printf '%s' "$notif" | grep -q 'NotFoundException'; then
    no_notif=1
  else
    warn 'could not read the notifications - this part is UNKNOWN'
    dim "$(printf '%s' "$notif" | head -1)"
    unknown=1
  fi
  notif='{"Notifications":[]}'
fi
# An empty list from a SUCCESSFUL call is the same finding as NotFoundException, and the API has
# been observed to return either. Folding them here means one branch below rather than two.
[[ "$(printf '%s' "$notif" | jq '[.Notifications[]?] | length')" == "0" && "$unknown" != "1" ]] && no_notif=1

got_thresholds=$(printf '%s' "$notif" | jq -c '[.Notifications[]?.Threshold] | sort')
got_types=$(printf '%s' "$notif" | jq -r '[.Notifications[]?.NotificationType] | unique | join(",")')

# ONE CAUSE, ONE FINDING. The first version of this section reported "no notifications" and then
# went on to report the empty threshold list, the empty type list AND the absence of subscribers -
# four failures for one cause, one of which actively misled by explaining that a FORECASTED alarm
# fires on noise when there was no alarm of any kind. That is the shape this repository keeps
# catching in its own checks ("one cause reported as two failures", parking lot, 2026-11-02), so
# the consequences are skipped rather than listed.
if (( no_notif )); then
  bad 'the budget exists and has NO notifications - it alerts at nothing'
  dim 'a budget with no notification is a line in a console and not a guardrail, and the'
  dim 'empty thresholds and missing subscribers below it are this, not separate problems'
  fail=1
elif (( unknown )); then
  : # nothing was read, so nothing is asserted - the exit-2 branch at the end says so
else
  if [[ "$(jq -n --argjson a "$got_thresholds" --argjson b "$want_thresholds" '$a == $b')" == "true" ]]; then
    ok "thresholds $got_thresholds match $CFG"
  else
    bad "thresholds are $got_thresholds, $CFG says $want_thresholds (percent)"
    fail=1
  fi

  # ACTUAL, not FORECASTED. A forecast alarm on a lab that is deliberately spiky fires constantly
  # and teaches you to ignore it - the same decision the GCP budget records as CURRENT_SPEND.
  if [[ "$got_types" == "ACTUAL" ]]; then
    ok 'all notifications are on ACTUAL spend, not FORECASTED'
  else
    bad "notification types are [$got_types], expected ACTUAL only"
    dim 'a FORECASTED alarm on a cluster that runs three hours a week fires on noise'
    fail=1
  fi
fi

# ---------------------------------------------------------------- subscribers: the AWS-only check
#
# THE ONE WITH NO GCP EQUIVALENT, and the reason this script is not a copy of the GCP one.
#
# Cloud Billing emails the billing account's admins by default, so a GCP budget with no notification
# channel still reaches a human. AWS Budgets notify nobody: a notification with an empty subscriber
# list is accepted and silent. So "is anyone subscribed" is not an unknown to be caveated at the
# end - it is readable, and its answer decides whether this guardrail can warn you at all.
if (( no_notif || unknown )); then
  # Skipped rather than reported empty. With no notifications there is nothing to subscribe TO, and
  # saying so again would be the fourth line about one cause; with the call unread there is nothing
  # to iterate. Named out loud so a reader is not left wondering whether the section ran.
  step 'and is anyone actually subscribed?'
  dim 'skipped - there is nothing to subscribe to, which the finding above already says'
else
step 'and is anyone actually subscribed?'
subs_total=0
subs_missing=()
while read -r t; do
  [[ -z "$t" ]] && continue
  s=$(aws budgets describe-subscribers-for-notification \
        --account-id "$acct" --budget-name "$NAME" \
        --notification "NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=$t,ThresholdType=PERCENTAGE" \
        --output json 2>/dev/null \
      | jq -r '[.Subscribers[]?.Address] | join(", ")' 2>/dev/null || true)
  if [[ -z "$s" ]]; then
    subs_missing+=("$t%")
  else
    subs_total=$((subs_total + 1))
    ok "at $t%: $s"
  fi
done < <(printf '%s' "$notif" | jq -r '.Notifications[]?.Threshold')

if (( ${#subs_missing[@]} > 0 )); then
  bad "NO subscriber at: ${subs_missing[*]}"
  dim 'AWS Budgets notify nobody by default, so these thresholds will be crossed in silence.'
  dim 'This is the failure mode the GCP guardrail cannot have, and it looks like success in'
  dim 'the console budget list.'
  fail=1
fi
fi

# ---------------------------------------------------------------- everything else on the account
others=$(printf '%s' "$raw" | jq -r --arg n "$NAME" \
  '.Budgets[] | select(.BudgetName != $n)
   | "      " + .BudgetName + "   " + (.BudgetLimit.Unit // "?") + " " + (.BudgetLimit.Amount // "?")')
if [[ -n "$others" ]]; then
  echo
  step 'other budgets on this account, which nothing here manages'
  printf '%s\n' "$others"
  printf '\n    %sNot a failure, and worth a look once.%s On GCP this listing is what revealed a budget\n' "$c_warn" "$c_off"
  printf '    named "(terraform)" belonging to an abandoned state - and a state that created a\n'
  printf '    budget may have created other things too. `make cost-check` is what answers that.\n'
fi

echo
if (( fail )); then
  die "the guardrail does not match what this repository asks for.
Re-apply it rather than editing it in the console, or the two disagree again tomorrow:
  make aws-guardrails"
fi

if [[ "${unknown:-0}" == "1" ]]; then
  warn 'the budget is right as far as could be read, and part of it could not be read'
  printf '\n  Treated as UNKNOWN rather than as a pass: the console is the authority.\n'
  printf '    https://us-east-1.console.aws.amazon.com/billing/home#/budgets\n'
  exit 2
fi

printf '%sthe guardrail is present and matches %s%s\n\n' "$c_ok" "$CFG" "$c_off"
printf 'What this still cannot tell you: %swhether that address is one you read%s. The subscriber\n' "$c_warn" "$c_off"
printf 'is confirmed to exist, which is further than the GCP check can get - but an address that\n'
printf 'bounces and one that works look identical from here. One look, once:\n'
printf '  https://us-east-1.console.aws.amazon.com/billing/home#/budgets\n\n'
printf 'AND THE LIMIT OF THIS WHOLE GUARDRAIL, which is sharper on AWS than on GCP: %sa budget\n' "$c_warn"
printf 'alerts, it does not stop anything%s. On the free account plan there is no spend cap at all -\n' "$c_off"
printf 'the limit that actually pauses resources exists only after upgrading to a paid plan. So\n'
printf '`make aws-down` is the control, and this is the thing that tells you it was forgotten.\n'
