#!/usr/bin/env bash
# What IS this AWS account, and what will it actually let us do?
#
#   open CloudShell in the console, then:
#     git clone https://github.com/Shaggydesai/platform-engineering-lab
#     cd platform-engineering-lab && bash scripts/aws-account-probe.sh
#
# READ-ONLY. It creates nothing, changes nothing, and deletes nothing. Every call below is a
# describe, a list or a get.
#
# WHY THIS EXISTS, and it is an admission rather than a design: ADR-0023 was written from AWS's
# documentation, and the documentation describes TWO DIFFERENT AWS ACCOUNTS under one name.
#
#   "Sign up for AWS (advanced)"  the classic account. A root user, IAM users that can sign into
#                                 the console, your own Organizations policies. This is what
#                                 every tutorial on the internet assumes.
#
#   "Sign up for AWS (new)"       the free-plan experience. AWS's own words: "You do not create a
#                                 root user", sign-in is an AWS Builder ID, "You can create IAM
#                                 roles and IAM users if necessary, but they can only be used for
#                                 PROGRAMMATIC ACCESS, NOT CONSOLE ACCESS", and AWS manages the
#                                 organization's SCPs and RCPs rather than you.
#
# ADR-0023's bootstrap tells you to give the new IAM user a console password and enrol its MFA
# device in the IAM console. On the second kind of account that instruction may be impossible, and
# the whole assume-role-with-MFA design rests on it.
#
# So: stop inferring, ask. Three of this project's worst hours came from a check that agreed with
# whoever wrote it, and reading a document is not a check.
set -uo pipefail

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
yes_() { printf '    %s[ yes ]%s %s\n' "$c_ok" "$c_off" "$*"; }
no_()  { printf '    %s[ no  ]%s %s\n' "$c_err" "$c_off" "$*"; }
unk()  { printf '    %s[  ?  ]%s %s\n' "$c_warn" "$c_off" "$*"; }
dim()  { printf '           %s%s%s\n' "$c_dim" "$*" "$c_off"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# AWS CLI v2 PIPES OUTPUT THROUGH A PAGER, and the first run of this probe is the evidence that it
# can reach a script: three calls came back with EMPTY output and an EMPTY error string, including
# `budgets describe-budgets` which SUCCEEDED and then reported "" budget(s) exist. An empty capture
# is indistinguishable from a silent API, which is the same failure this repository keeps finding
# in its own checks - a result that cannot tell "nothing" from "I did not see".
#
# The pager is supposed to disengage when stdout is not a terminal. Rather than reason about when
# that holds inside command substitution under WSL, it is turned off outright.
export AWS_PAGER=""

command -v aws >/dev/null || { echo "the AWS CLI is not on PATH - run this in CloudShell"; exit 1; }
command -v jq  >/dev/null || { echo "jq is not on PATH - run this in CloudShell"; exit 1; }

# A helper that turns "did this API call work" into THREE answers rather than two. A call that
# fails with AccessDenied is a real answer - the permission is not there. A call that fails with a
# throttle, a network error or an unknown service is NOT an answer, and reporting it as a denial
# is the shape that cost an hour in Module 07 (`eso-check`, parking lot 2026-10-30).
try() {
  local label="$1"; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  if (( rc == 0 )); then
    yes_ "$label"
    LAST_OUT="$out"
    return 0
  fi
  LAST_OUT=''
  case "$out" in
    *AccessDenied*|*UnauthorizedOperation*|*not\ authorized*|*AuthorizationError*|*explicit\ deny*)
      no_ "$label"
      printf '%s\n' "$out" | head -3 | sed "s/^/           /"
      return 1 ;;
    *OptInRequired*|*not\ subscribed\ to\ this\ service*)
      # NOT an unknown, and not a permission problem either. This is AWS saying the ACCOUNT is
      # not activated for the service - which on a new account means registration or payment
      # verification has not completed, however working the console looks and however many
      # credits the console reports.
      no_ "$label - THE ACCOUNT IS NOT SUBSCRIBED TO THIS SERVICE"
      printf '%s\n' "$out" | head -3 | sed "s/^/           /"
      ACCOUNT_NOT_ACTIVATED=1
      return 1 ;;
    *)
      unk "$label - the call failed for a reason that is not a denial"
      printf '%s\n' "$out" | head -3 | sed "s/^/           /"
      return 2 ;;
  esac
}
ACCOUNT_NOT_ACTIVATED=0

printf '%sWhat is this AWS account, and what will it let us do?%s\n' "$c_step" "$c_off"
printf '%sread-only: every call below is a describe, a list or a get%s\n' "$c_dim" "$c_off"

# ---------------------------------------------------------------- 1. who
step 'who are these credentials?'
if ! who=$(aws sts get-caller-identity --output json 2>&1); then
  no_ 'no working credentials at all'
  dim "$(printf '%s' "$who" | head -1)"
  echo; echo "Run this in CloudShell, which inherits the console session you are already signed into."
  exit 1
fi
acct=$(printf '%s' "$who" | jq -r '.Account')
arn=$(printf '%s'  "$who" | jq -r '.Arn')
yes_ "account $acct"
yes_ "caller  $arn"

case "$arn" in
  *:root)
    dim 'ROOT. `aws login` issues root credentials on this account - short-lived (12h) and' ;
    dim 'obtained through an MFA-protected browser session, which is a different thing from a' ;
    dim 'root ACCESS KEY, but still the unrestricted principal (ADR-0024).' ;;
  *:assumed-role/*)
    dim 'An assumed role. On the new sign-up experience this is normal even in the console -' ;
    dim 'the Builder ID federates into a role rather than signing in as a root user.' ;;
  *:user/*)
    dim 'An IAM user.' ;;
  *) dim 'An identity shape this script does not recognise - worth reading carefully.' ;;
esac

# ---------------------------------------------------------------- 2. which kind of account
#
# THE QUESTION ADR-0023 GOT WRONG. AWS manages the Organization on the new sign-up experience, so
# an organization this account did not create is the clearest available tell. It is a heuristic
# and is labelled as one: a denial here is itself informative (Organizations is on the
# not-supported list for the free plan), so BOTH outcomes mean something.
step 'classic account, or the new free-plan experience?'
if try 'Organizations is readable' aws organizations describe-organization --output json; then
  master=$(printf '%s' "$LAST_OUT" | jq -r '.Organization.MasterAccountId // "?"')
  if [[ "$master" == "$acct" ]]; then
    dim "this account ($acct) is the management account of its own organization"
    dim 'consistent with a CLASSIC account that someone created an org in'
  else
    dim "the management account is $master, which is NOT this account"
    dim 'consistent with the NEW experience, where AWS owns the organization above you'
    dim 'and manages its SCPs and RCPs - meaning there may be denials you cannot see or change'
  fi
else
  dim 'Organizations unreadable. Expected on the free plan, which lists it as not supported,'
  dim 'so this tells us little on its own - the IAM answers below are the decisive ones.'
fi

# ---------------------------------------------------------------- 3. MFA and what exists
step 'MFA, and what identities already exist'
if try 'the account summary is readable' aws iam get-account-summary --output json; then
  mfa=$(printf '%s' "$LAST_OUT" | jq -r '.SummaryMap.AccountMFAEnabled // "?"')
  if [[ "$mfa" == "1" ]]; then
    yes_ 'the account root/sign-in identity has an MFA device'
  elif [[ "$mfa" == "0" ]]; then
    no_ 'NO MFA on the account sign-in identity'
    dim 'On the new experience this is enrolled at https://settings.aws.com ->'
    dim 'Manage security and sign-in -> Security -> Register device, NOT in IAM.'
  else
    unk 'AccountMFAEnabled was not in the summary'
  fi
  for k in Users Roles Policies MFADevices; do
    printf '           %s%-12s %s%s\n' "$c_dim" "$k" \
      "$(printf '%s' "$LAST_OUT" | jq -r --arg k "$k" '.SummaryMap[$k] // "?"')" "$c_off"
  done
fi

try 'iam:ListUsers'             aws iam list-users --max-items 5 --output json
try 'iam:ListRoles'             aws iam list-roles --max-items 5 --output json
try 'iam:ListVirtualMFADevices' aws iam list-virtual-mfa-devices --max-items 5 --output json

# ---------------------------------------------------------------- 4. can the bootstrap run?
#
# SIMULATED, NOT ATTEMPTED. `simulate-principal-policy` asks IAM what WOULD happen without doing
# it, which is the only honest way to answer "will the bootstrap work" from a read-only script.
#
# Its own caveat, stated because it matters here: the simulator evaluates identity and resource
# policies and SCPs, but AWS documents it as not always reflecting every condition. On an account
# where AWS manages the SCPs (see section 2) a simulated allow is good evidence and not a promise.
step 'would the ADR-0023 bootstrap be permitted?'
# `if sim=$(...)` rather than assigning and then testing $? on the next line: that pattern read
# the exit status of `head` instead of the command it meant, in scripts/gcp-smoke.sh, on 2026-11-02.
if sim=$(aws iam simulate-principal-policy \
           --policy-source-arn "$arn" \
           --action-names iam:CreateUser iam:CreateRole iam:AttachRolePolicy iam:PutUserPolicy \
                          iam:CreateAccessKey iam:EnableMFADevice iam:CreateVirtualMFADevice \
           --output json 2>&1); then
  printf '%s' "$sim" | jq -r '.EvaluationResults[]
    | "    " + (if .EvalDecision == "allowed" then "[ yes ]" else "[ no  ]" end)
      + " " + .EvalActionName + "   " + .EvalDecision'
  dim 'simulate-principal-policy answers "what would happen", without doing it'
else
  case "$sim" in
    *AccessDenied*|*not\ authorized*)
      no_ 'cannot simulate - iam:SimulatePrincipalPolicy is itself denied'
      dim 'which is already an answer about how constrained this identity is' ;;
    *InvalidInput*|*ValidationError*)
      unk 'the simulator rejected this principal ARN'
      dim 'federated and assumed-role ARNs are not always valid policy sources' ;;
    *) unk 'the simulator call failed for a reason that is not a denial' ;;
  esac
  printf '%s\n' "$sim" | head -3 | sed "s/^/           /"
fi

# ---------------------------------------------------------------- 5. the guardrail
step 'can the budget guardrail be created and read? (ADR-0003 Decision 3)'
# NotFoundException IS A SUCCESS HERE, and it is handled before `try` rather than inside it,
# because `try` would correctly call it "a failure that is not a denial" and print a [ ? ].
# "There are no budgets yet" is a complete, correct answer to "can I read budgets" - and on the
# one gate standing between this repository and a billable cluster, a question mark that means
# "yes" is worth three lines to avoid.
if bud=$(aws budgets describe-budgets --account-id "$acct" --output json 2>&1); then
  n_bud=$(printf '%s' "$bud" | jq '.Budgets | length' 2>/dev/null)
  # The API returns NOTHING at all when there are no budgets, rather than an empty list, so an
  # empty capture here means zero and not "I could not see". The first version printed
  # "  budget(s) exist" with a hole where the number should be.
  yes_ "budgets:DescribeBudgets - ${n_bud:-0} budget(s) exist"
elif printf '%s' "$bud" | grep -q 'NotFoundException'; then
  yes_ 'budgets:DescribeBudgets - readable, and this account has no budgets yet'
  dim 'which is the expected state before `make aws-guardrails` has ever run'
elif printf '%s' "$bud" | grep -qE 'AccessDenied|not authorized'; then
  no_ 'budgets:DescribeBudgets is DENIED'
  dim 'ADR-0003 Decision 3 cannot be satisfied without this - the alarm must be readable'
  dim 'back out of the API, not merely applied'
else
  unk 'budgets:DescribeBudgets failed for a reason that is not a denial'
  printf '%s\n' "$bud" | head -3 | sed "s/^/           /"
fi

# ---------------------------------------------------------------- 6. where things can be built
step 'which regions are enabled, and is the configured one among them?'
want=$(jq -r '.region' clusters/aws/cluster.json 2>/dev/null || echo '?')
if try 'ec2:DescribeRegions' aws ec2 describe-regions --output json; then
  regions=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>/dev/null)
  n=$(printf '%s\n' $regions | grep -c .)
  dim "$n enabled"
  if printf '%s\n' $regions | grep -qx "$want"; then
    yes_ "clusters/aws/cluster.json asks for $want, and it is enabled"
  else
    no_ "clusters/aws/cluster.json asks for $want, which is NOT in the enabled list"
  fi
fi

step 'is m6a.large actually offered there? (the pin clusters/aws/cluster.json says is unverified)'
# SKIPPED, not re-reported. The region call above already found the account unsubscribed to EC2,
# and this is the same cause - listing it twice is the "one cause, several findings" shape that
# this repository has caught in gcp-smoke and aws-guardrails-verify already.
if (( ACCOUNT_NOT_ACTIVATED )); then
  dim 'skipped - EC2 is not available to this account, which the finding above already says'
elif offers=$(aws ec2 describe-instance-type-offerings --region "$want" \
              --filters Name=instance-type,Values=m6a.large \
              --query 'InstanceTypeOfferings[].Location' --output text 2>&1); then
  if [[ -n "$offers" && "$offers" != "None" ]]; then
    yes_ "m6a.large is offered in $want"
  else
    no_ "m6a.large is NOT offered in $want - change it to m5.large in clusters/aws/cluster.json"
    dim 'do NOT reach for t3.large: it is burstable, and that is the silent failure ADR-0022'
    dim 'exists to prevent (e2-medium, 940m allocatable, six pods Pending)'
  fi
else
  unk 'could not ask about instance type offerings'
  printf '%s\n' "$offers" | head -3 | sed "s/^/           /"
fi

printf '\n%s%s%s\n' "$c_step" '--------------------------------------------------------------' "$c_off"

# THE VERDICT, because the first version of this script had none and buried its most important
# finding between two others. A reader should not have to notice which of eleven lines mattered.
if (( ACCOUNT_NOT_ACTIVATED )); then
  printf '\n%sTHIS ACCOUNT IS NOT ACTIVATED FOR EC2.%s Nothing in Module 09 can be built until it is:\n' "$c_err" "$c_off"
  printf 'no instances, therefore no EKS nodes, therefore no cluster. A working console and a\n'
  printf 'credit balance do not mean activation finished - OptInRequired is the API saying so.\n\n'
  printf '  1. https://signup.aws.amazon.com/billing/signup/incomplete  -> Complete your AWS registration\n'
  printf '  2. Check email, including spam, for anything AWS asked for\n'
  printf '  3. Check the card for a pending ~$1 authorization. In India an international\n'
  printf '     authorization often needs explicit approval from the bank or its app, and AWS\n'
  printf '     activation stalls silently until it clears.\n'
  printf '  4. Still failing 24h after sign-up: AWS Support, Account and Billing, which is free.\n\n'
  printf '%sDo NOT click "Upgrade plan" to try to fix this%s - it is irreversible, it makes the\n' "$c_warn" "$c_off"
  printf 'account liable for charges above the credits, and it is not what OptInRequired means.\n'
fi

printf '\nPaste this whole output back. It decides which ADR-0023 path is actually available,\n'
printf 'and nothing here changed anything.\n'
