#!/usr/bin/env bash
# Create the identity this lab operates as, so that nothing after this runs as root.
#
# RUN IT ONCE, IN CLOUDSHELL, SIGNED IN AS ROOT:
#
#   git clone https://github.com/Shaggydesai/platform-engineering-lab
#   cd platform-engineering-lab && bash scripts/aws-bootstrap-identity.sh
#
# WHY CLOUDSHELL AND NOT YOUR LAPTOP, which is the whole point of the arrangement: CloudShell runs
# with the credentials of the console session you are already signed into, so root can create these
# objects WITHOUT EVER MINTING A ROOT ACCESS KEY. A root access key is the single worst credential
# on AWS - it cannot be scoped by any policy, it can change the payment method and close the
# account, and it is the one credential whose leak has no recovery story. This script exists so
# that one never has to exist.
#
# WHY A SCRIPT AND NOT TERRAFORM, which is a deliberate exception to ADR-0002 Rule 3 rather than an
# oversight. Terraform would need credentials to create the IAM user, and the IAM user is what
# supplies the credentials - the same bootstrap problem that makes the GCP PROJECT a hand-made
# object (clusters/gcp/cluster.json: "it is the container the Terraform state lives inside, so it
# cannot be created by that state"). Everything downstream of this - the budget, the cluster, the
# platform - is Terraform and Argo CD as usual.
#
# WHAT IT DELIBERATELY DOES NOT DO: create an access key. See the end of the script.
#
# It is IDEMPOTENT. Run it again and it reports what already exists and changes nothing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CFG=clusters/aws/cluster.json
USER_NAME=platform-lab
ROLE_NAME=platform-lab-admin

# FOUR HOURS, not the one-hour default, and this is a trade worth seeing.
#
# Every assume-role call requires a fresh MFA code, so a short duration means re-entering one
# mid-session - and an EKS cluster takes ~15 minutes to create while `terraform apply` holds the
# credentials. A session that expires inside a non-interactive apply fails in a way that reads like
# a permissions problem rather than an expiry.
#
# Four hours covers a lab session and is still nothing like a long-lived key: it cannot be obtained
# at all without a code from your phone, and it dies on its own. The maximum AWS allows is twelve.
MAX_SESSION=14400

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
same() { printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; }
warn() { printf '    %s%s%s\n' "$c_warn" "$*" "$c_off"; }
die()  { printf '\n%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

command -v aws >/dev/null || die 'the AWS CLI is not on PATH. CloudShell has it preinstalled - run this there.'
command -v jq  >/dev/null || die 'jq is not on PATH. CloudShell has it preinstalled - run this there.'
[[ -r "$CFG" ]] || die "cannot read $CFG - run this from the repository root."

region=$(jq -r '.region' "$CFG")

# ---------------------------------------------------------------- who is running this
#
# AND IT MUST BE ROOT, which is the opposite of every other check in this repository.
#
# Root is the only principal that is guaranteed to be able to create an IAM user and role on a
# brand-new account, because it is the only one that exists. Refusing to run as anything else is
# not pedantry: an IAM user creating a MORE privileged role than itself is a privilege-escalation
# path, and if this script ever appears to work from a non-root principal it is worth knowing why.
step 'who is running this?'
caller=$(aws sts get-caller-identity --output json 2>&1) \
  || die "the AWS CLI has no working credentials.
Run this in CloudShell (bottom-left of the console) while signed in as root - it inherits that
session, which is the entire reason this script exists."

arn=$(printf '%s' "$caller" | jq -r '.Arn')
acct=$(printf '%s' "$caller" | jq -r '.Account')
ok "account $acct"
ok "caller  $arn"

if [[ "$arn" != *":root" ]]; then
  warn 'this is NOT the root user'
  same 'That is usually right and wrong here. This script bootstraps the identity that replaces'
  same 'root, so running it as something else means either it has already been run (in which case'
  same 'there is nothing to do) or a non-root principal is about to create a role more privileged'
  same 'than itself.'
  printf '\n  Continue anyway? [y/N] '
  read -r reply
  [[ "$reply" == [yY] ]] || die 'stopped.'
fi

# ---------------------------------------------------------------- root's own MFA
#
# READ, NOT ASSUMED. This is the one property of the account that matters most and the one nothing
# in this repository can create: virtual MFA enrolment needs the QR secret, which would land in a
# script's output or a Terraform state. So it is done by hand, once - and checked here every run so
# that "I'll do it later" cannot quietly become never.
step "is root's MFA enabled?"
if mfa=$(aws iam get-account-summary --query 'SummaryMap.AccountMFAEnabled' --output text 2>/dev/null); then
  if [[ "$mfa" == "1" ]]; then
    ok 'root has an MFA device'
  else
    warn 'ROOT HAS NO MFA DEVICE'
    same 'Root cannot be restricted by any policy - it can change the payment method, spend the'
    same 'credits and close the account - so MFA is the whole of its defence. Do it before you'
    same 'sign out of this session:'
    same '  console -> your name (top right) -> Security credentials -> Multi-factor authentication'
    root_mfa_missing=1
  fi
else
  warn "could not read the account summary, so root's MFA state is UNKNOWN"
  same 'not a pass - check it by hand in Security credentials'
fi

# ---------------------------------------------------------------- the user
step "the IAM user this lab operates as: $USER_NAME"
if aws iam get-user --user-name "$USER_NAME" >/dev/null 2>&1; then
  same "already exists - not touched"
else
  aws iam create-user --user-name "$USER_NAME" \
    --tags Key=project,Value=platform-engineering-lab Key=managed_by,Value=bootstrap-script \
    >/dev/null || die "could not create the user $USER_NAME"
  ok "created"
fi

# ---------------------------------------------------------------- the role
#
# THE TRUST POLICY IS THE SECURITY CONTROL, not the permissions policy. AdministratorAccess on the
# role is deliberately broad - this is a lab that creates VPCs, clusters and IAM roles for IRSA, so
# a hand-curated policy would be a week of least-privilege work that is wrong in a different way
# every time a module adds a service.
#
# What makes that safe is the condition below: the role can only be assumed by this one user, and
# only when a multi-factor code was presented. An access key on the laptop is therefore not a
# credential for anything - on its own it can assume nothing, and the only thing it is permitted to
# attempt requires a code from a device that is not the laptop.
#
# MultiFactorAuthAge is the second half of it. Without it, a code entered once at the start of the
# day would authorise assume-role calls for as long as the user's session lasted; 3600 means the
# code itself must be recent, not merely to have happened.
step "the admin role: $ROLE_NAME"
trust=$(jq -nc --arg u "arn:aws:iam::${acct}:user/${USER_NAME}" '
  {Version: "2012-10-17",
   Statement: [{
     Effect: "Allow",
     Principal: {AWS: $u},
     Action: "sts:AssumeRole",
     Condition: {
       Bool:         {"aws:MultiFactorAuthPresent": "true"},
       NumericLessThan: {"aws:MultiFactorAuthAge": "3600"}
     }}]}')

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  same 'already exists - updating its trust policy and session duration to match this script'
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "$trust" >/dev/null || die 'could not update the trust policy'
  aws iam update-role --role-name "$ROLE_NAME" \
    --max-session-duration "$MAX_SESSION" >/dev/null || die 'could not update the session duration'
  ok "trust policy and ${MAX_SESSION}s session duration re-applied"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$trust" \
    --max-session-duration "$MAX_SESSION" \
    --description "platform-engineering-lab: admin, assumable only with MFA" \
    --tags Key=project,Value=platform-engineering-lab Key=managed_by,Value=bootstrap-script \
    >/dev/null || die "could not create the role $ROLE_NAME"
  ok "created, max session ${MAX_SESSION}s"
fi

aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess >/dev/null \
  || die 'could not attach AdministratorAccess to the role'
ok 'AdministratorAccess attached to the ROLE (not to the user)'

# ---------------------------------------------------------------- what the user may do
#
# ALMOST NOTHING, and that is the design. The user holds the long-lived credential, so the user is
# what an attacker gets. It may assume one role (with MFA), and manage its own MFA device and its
# own access keys so that rotation never needs root again.
#
# The self-service block is the fiddly part of this policy and it is not optional: without it, the
# user cannot enrol the MFA device that the role's trust policy requires, and the account is back
# to needing root for routine work. The two statements differ on purpose - listing devices has to
# be permitted account-wide because the API takes no resource, while creating and enabling one is
# scoped to this user's own device.
step "what $USER_NAME is allowed to do"
user_policy=$(jq -nc --arg r "arn:aws:iam::${acct}:role/${ROLE_NAME}" \
                     --arg u "$USER_NAME" '
  {Version: "2012-10-17",
   Statement: [
     {Sid: "AssumeTheAdminRoleWithMFA", Effect: "Allow", Action: "sts:AssumeRole", Resource: $r},
     {Sid: "SeeOwnIdentity", Effect: "Allow",
      Action: ["iam:GetUser", "iam:ListMFADevices", "iam:ListVirtualMFADevices",
               "iam:ListAccessKeys", "iam:GetAccountPasswordPolicy"],
      Resource: "*"},
     {Sid: "ManageOwnMFADevice", Effect: "Allow",
      Action: ["iam:CreateVirtualMFADevice", "iam:DeleteVirtualMFADevice",
               "iam:EnableMFADevice", "iam:ResyncMFADevice", "iam:DeactivateMFADevice"],
      Resource: ["arn:aws:iam::*:mfa/\($u)", "arn:aws:iam::*:user/\($u)"]},
     {Sid: "RotateOwnAccessKeys", Effect: "Allow",
      Action: ["iam:CreateAccessKey", "iam:DeleteAccessKey", "iam:UpdateAccessKey",
               "iam:ChangePassword"],
      Resource: "arn:aws:iam::*:user/\($u)"}
   ]}')

aws iam put-user-policy --user-name "$USER_NAME" \
  --policy-name platform-lab-assume-admin \
  --policy-document "$user_policy" >/dev/null \
  || die 'could not attach the inline policy to the user'
ok 'may assume one role (with MFA), and manage only its own MFA device and keys'
ok 'has NO permissions of its own - everything else comes from the role'

# ---------------------------------------------------------------- and what this does not do
step 'what this script deliberately did NOT do'
printf '    %sIt did not create an access key.%s A key created by a script ends up in the script'"'"'s\n' "$c_warn" "$c_off"
printf '    output, in a scrollback buffer, and often in a terminal log - and an AWS secret access\n'
printf '    key is shown exactly once and never again, so the moment it is printed it is also\n'
printf '    somewhere it should not be.\n\n'
printf '    This is the same decision terraform/gcp/secrets makes by having no\n'
printf '    google_secret_manager_secret_version: Terraform writes every managed attribute into\n'
printf '    local state in plaintext, and `sensitive` suppresses output, not state (ADR-0018).\n'

# ---------------------------------------------------------------- next
printf '\n%s%s%s\n' "$c_step" '--------------------------------------------------------------------' "$c_off"
printf '\n%sDone. Four steps, in this order, and the first two are in the console.%s\n\n' "$c_ok" "$c_off"

if [[ "${root_mfa_missing:-0}" == "1" ]]; then
  printf '  %s0. ROOT STILL HAS NO MFA. Do this before anything else.%s\n' "$c_err" "$c_off"
  printf '     console -> your name -> Security credentials -> Multi-factor authentication\n\n'
fi

cat <<EOF
  1. Give $USER_NAME a console password and an MFA device.
     IAM -> Users -> $USER_NAME -> Security credentials
       - "Console sign-in" : enable, set a password
       - "Multi-factor authentication (MFA)" : assign a device
     THE MFA DEVICE IS NOT OPTIONAL. The role's trust policy requires a code, so without
     one this user can do nothing at all - which is the intended failure mode.

  2. Create ONE access key for $USER_NAME, in the console, and put it straight into the
     CLI on your laptop. Do not paste it anywhere else, and do not store it.
     IAM -> Users -> $USER_NAME -> Security credentials -> Create access key
       (choose "Command Line Interface", and ignore the warning about alternatives -
        the alternative it recommends is IAM Identity Center, which the free account
        plan does not support)

  3. On your laptop, two profiles. The first holds the key and can do nothing;
     the second is the one you use:

       aws configure --profile platform-lab-user
         # paste the key and secret, region $region, output json

       aws configure set --profile platform-lab \\
         role_arn arn:aws:iam::${acct}:role/${ROLE_NAME}
       aws configure set --profile platform-lab source_profile platform-lab-user
       aws configure set --profile platform-lab mfa_serial \\
         arn:aws:iam::${acct}:mfa/${USER_NAME}
       aws configure set --profile platform-lab region $region

     Then make it the default for this lab, so nothing has to remember a flag:

       export AWS_PROFILE=platform-lab        # add it to ~/.bashrc

  4. Prove it works. This should PROMPT FOR AN MFA CODE and then print the ROLE'S arn,
     not the user's:

       aws sts get-caller-identity

     Expect:  arn:aws:sts::${acct}:assumed-role/${ROLE_NAME}/botocore-session-...

     If it prints the USER's arn instead, AWS_PROFILE is not set and you are about to
     build a lab with a credential that was supposed to be powerless.

  Then, from the repository:

       make aws-guardrails AWS_ALERT_EMAIL=you@example.com
       make aws-guardrails-verify

  and \`make aws-guardrails\` will refuse to run if it is ever called as root again.
EOF
