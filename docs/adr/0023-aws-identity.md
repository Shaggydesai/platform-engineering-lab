# ADR-0023: operating AWS without Identity Center, and never as root

**Status:** Accepted
**Date:** 2026-11-04
**Decides:** which identity this lab builds AWS resources as, how its credentials are obtained,
why the bootstrap is a script rather than Terraform, and why no machine in this repository ever
creates an access key. Ports ADR-0018's "no long-lived credential on the laptop" rule to AWS.

## Context

The account exists: created 2026-11-04 on the free account plan, $100 of credits, free access
ending 2027-05-04. The first session was signed in **as root**, which is how every AWS account
starts and is not a state to stay in.

ADR-0018 established the rule for GCP and spent a module enforcing it: **no service-account key
file anywhere, ever.** Terraform authenticates with Application Default Credentials, obtained by
`gcloud auth application-default login` — short-lived, browser-obtained, refreshed on demand.

The obvious AWS analogue is **IAM Identity Center** (`aws sso login`), which produces exactly that
shape of credential.

**It is not available.** AWS lists both **IAM Identity Center** and **AWS Organizations** in the
*not supported* column for the free account plan. IAM and STS are supported, as are EC2, EKS, EBS,
VPC, ELB, Secrets Manager, KMS, Route 53 and Budgets. So the SSO path is closed, and was closed
before any time was spent on it only because the supported-services list was read rather than
assumed — the recommendation in this session's first draft was Identity Center.

## Decision

### 1. Root gets MFA and nothing else, and it never gets an access key

Root is the only principal on an AWS account that **cannot be restricted by any policy**. It can
change the payment method, spend the credits and close the account. There is no IAM policy, no
permission boundary and — without Organizations — no SCP that constrains it.

MFA on root is therefore the whole of its defence, and it is the one property of this account that
nothing in this repository can create: enrolling a virtual MFA device requires the QR secret, which
would land in a script's output or a Terraform state. **It is done by hand, once.**
`scripts/aws-bootstrap-identity.sh` reads `SummaryMap.AccountMFAEnabled` on every run and says so
loudly when it is 0, so "I'll do it later" cannot quietly become never.

**A root access key must not exist.** It is the one AWS credential whose leak has no recovery
story, and the CLI never needs one — see Decision 3.

### 2. An almost-powerless IAM user, and an admin role that requires MFA to assume

- `platform-lab`, an IAM user with **no permissions of its own**. Its inline policy allows exactly
  `sts:AssumeRole` on one role, plus management of its own MFA device and its own access keys so
  that rotation never needs root again.
- `platform-lab-admin`, a role with `AdministratorAccess`, whose **trust policy** is the security
  control:

  ```json
  "Condition": {
    "Bool":            {"aws:MultiFactorAuthPresent": "true"},
    "NumericLessThan": {"aws:MultiFactorAuthAge":     "3600"}
  }
  ```

**Why the role's permissions are broad and that is fine.** This lab creates VPCs, EKS clusters and
IAM roles for IRSA; a hand-curated least-privilege policy would be a week of work that breaks in a
new way every time a module adds a service. What makes it safe is that the long-lived credential
cannot reach it: an access key on the laptop can attempt exactly one action, and only with a code
from a device that is not the laptop.

`MultiFactorAuthAge` is the half that is easy to omit. Without it, a code entered once at the start
of the day authorises assume-role calls for the life of the session; with it, the code must be
*recent*, not merely to have happened at some point.

**Four-hour sessions, not the one-hour default.** An EKS cluster takes ~15 minutes to create while
`terraform apply` holds the credentials, and a session expiring inside a non-interactive apply
fails in a way that reads like a permissions problem. Four hours covers a lab session and is still
nothing like a long-lived key: it cannot be obtained without a code, and it dies on its own.

### 3. The bootstrap is a script, run in CloudShell, and that is a deliberate exception to ADR-0002 Rule 3

Terraform would need credentials to create the IAM user, and the IAM user is what supplies the
credentials. That is the same bootstrap problem that makes the GCP **project** a hand-made object:
*"it is the container the Terraform state lives inside, so it cannot be created by that state."*

**CloudShell is what removes the last reason to mint a root key.** It runs with the credentials of
the console session already signed in, so root can create these objects without a key existing
anywhere, ever. The repository is public, so the whole bootstrap is two commands:

```bash
git clone https://github.com/Shaggydesai/platform-engineering-lab
cd platform-engineering-lab && bash scripts/aws-bootstrap-identity.sh
```

The script is idempotent and re-applies the trust policy and session duration on every run, so the
file in Git stays the description of what the account has. Everything downstream of it — the
budget, the cluster, the platform — is Terraform and Argo CD as usual.

### 4. No machine in this repository creates an access key

The bootstrap deliberately does **not** call `iam create-access-key`. An AWS secret access key is
displayed exactly once and never again, so the moment a script prints it, it is also in a
scrollback buffer and often in a terminal log.

This is the same decision `terraform/gcp/secrets` makes by having no
`google_secret_manager_secret_version`: Terraform writes every managed attribute into local state
in plaintext, and `sensitive` suppresses *output*, not *state* (ADR-0018). The key is created in
the console, by hand, and goes straight into `aws configure`.

### 5. `make aws-guardrails` refuses root, and says so about a bare IAM user

Reading `sts:GetCallerIdentity` costs one call and turns a convention into a mechanism:

- **ARN ends in `:root`** → refuse, and say that a root access key should not exist at all, with
  the console link that deletes it.
- **ARN is `:user/...`** → proceed, with a warning. It works, and on an account that never ran the
  bootstrap it is the only thing that can — but it means the long-lived key *is* the credential.
  In practice this is `AWS_PROFILE` being unset, which is worth naming because the symptom is
  silence.
- **ARN is `:assumed-role/...`** → silent, which is the intended state.

## Amendment, same day: the documentation describes two different AWS accounts

Everything above was written from AWS's documentation, and the documentation uses one name for two
products. **Clicking "Security credentials" on this account redirects to
`signup.aws.amazon.com/billing/signup/incomplete`**, whose own text says: *"either not finished
registering, **or your account is currently on free plan**."*

| | Sign up for AWS (advanced) | **Sign up for AWS (new)** — the free plan |
|:--|:--|:--|
| Sign-in identity | a root user | an **AWS Builder ID**; AWS's words: *"You do not create a root user"* |
| MFA lives at | IAM → Security credentials | **settings.aws.com** → Manage security and sign-in → Security → Register device |
| IAM users | console **and** programmatic | *"can only be used for **programmatic access, not console access**"* |
| Organization policies | yours | **AWS manages the SCPs and RCPs** |
| AWS's own advice | — | *"If you need fine-grained control over your users or role-based permissions, do not use Sign up for AWS (new)"* |

**This puts Decision 2's bootstrap in question, and the questionable part is a step a human
performs.** `scripts/aws-bootstrap-identity.sh` ends by telling the operator to give `platform-lab`
a console password and enrol its MFA device in the IAM console. On the new experience that may be
impossible. The *design* may survive — MFA on an IAM user is an API-level fact and is separate from
console sign-in, so `iam:CreateVirtualMFADevice` + `iam:EnableMFADevice` could still produce the
`aws:MultiFactorAuthPresent` the trust policy needs — but **may** is doing real work in that
sentence and nothing here has tested it.

**So the next step is not another document, it is a question put to the API.**
`scripts/aws-account-probe.sh` is read-only and reports, with three outcomes each: which identity
shape the credentials are, whether an Organization sits above this account that it does not manage,
whether MFA is enrolled, whether `iam:CreateUser`/`CreateRole`/`EnableMFADevice` would be permitted
(via `simulate-principal-policy`, which answers without doing), whether Budgets is readable, and —
while it is there — whether `m6a.large` is genuinely offered in `ap-south-1`, which
`clusters/aws/cluster.json` has carried as an unverified pin since ADR-0022.

**The lesson is the one this project keeps relearning, in a new place.** Every previous instance
was a *check* that confirmed a request was recorded rather than that it took effect. This one is a
*plan* built on a document that described a different product, and it would have been found by the
first human step failing — after the IAM objects existed and the operator was three screens deep.
**Reading a document is not a check.**

## Consequences

**`make cost-check` now sweeps every enabled region, and the reason is a near miss.** The AWS half
was `for r in ap-south-1 us-east-1`, written when ap-south-1 was chosen. The console opened in
**eu-north-1** — AWS's own default for this account — which is where a stray click would have
built, and the check would have reported clean.

**That is the third time this lesson has arrived here**, which is why the fix is the default rather
than another widening:

| | what was too narrow | what it hid |
|:--|:--|:--|
| 2026-10-31 | the project `gcloud config` pointed at | ₹591 of charges in another project |
| 2026-10-31 | compute and GKE only | a bucket, a KMS keyring, an Artifact Registry |
| 2026-11-04 | two hardcoded AWS regions | anything at all in the region the console opens in |

**A sweep is exactly as wide as the list somebody wrote, and nobody revisits that list.** So the
list is no longer written: `describe-regions` returns the regions this account has enabled, and
that answer changes when the account does. It costs 30–60 seconds on ~17 regions, said out loud in
the output, on a command that runs once at the end of a session. When the region list itself cannot
be read, the sweep narrows to the configured region and **says so** rather than falling back
silently — ADR-0003's three-outcome rule, in the cost path.

AWS findings also carry their own remove command now. The verdict line has promised one since
Module 08 (*"each finding above carries its own remove command"*) and for AWS it was simply untrue.
The EKS line points at `make aws-down` rather than `aws eks delete-cluster`, because ADR-0021's
ordering rule applies: the load balancers and volumes its controllers created must go first.

**What is NOT verified, and it is all of it:**

- **Nothing has been run.** The bootstrap was exercised against a stub `aws` CLI across seven paths
  (fresh account, already-bootstrapped, root without MFA, unreadable account summary, non-root
  caller answering yes and no, and absent credentials), and both generated IAM policy documents
  were checked as JSON. **A stub is not IAM.** The specific things a real run could still reject:
  the `iam:*` action names in the self-service block, the `arn:aws:iam::*:mfa/<user>` resource
  form, and whether `update-role --max-session-duration` is permitted on a role that already has
  the policy attached.
- **That `aws configure set --profile X role_arn/mfa_serial` produces a profile the CLI accepts.**
  It is the documented shape; it has not been seen to prompt for a code on this machine.
- **That the free account plan permits `iam:CreateRole` with `AdministratorAccess` attached.** IAM
  is on the supported list; a plan-level restriction on attaching that specific managed policy
  would not be visible from the list.
- **That root MFA has been enabled.** The script reports it; nobody has run the script.
