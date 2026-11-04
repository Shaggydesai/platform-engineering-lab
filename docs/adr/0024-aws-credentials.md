# ADR-0024: `aws login` — the credential model this account already had

**Status:** Accepted. **Supersedes ADR-0023.**
**Date:** 2026-11-04
**Decides:** how the CLI and Terraform authenticate to AWS. Ports ADR-0018's "no long-lived
credential on the laptop" rule to AWS — by using what the platform provides rather than
reconstructing it.

## Context

ADR-0023 spent a day building an identity scheme for this account: an almost-powerless IAM user, an
admin role whose trust policy demands a recent MFA code, and a CloudShell bootstrap so that root
would never need an access key. It was careful, it was tested against stubs, and **it was solving a
problem this account does not have.**

Three observations, in the order they arrived, each one narrowing it:

1. **"Security credentials" redirects** to `signup.aws.amazon.com/billing/signup/incomplete`.
2. **MFA lives on an AWS Builder ID**, at `settings.aws.com`. The profile page says so in its own
   heading. There is no classic root user on this account — AWS's words: *"You do not create a root
   user."*
3. **The IAM console redirects to the same page**, and **CloudShell will not provision**.

At that point the conclusion looked like a dead end: no IAM console, no CloudShell, no root — so no
way to create the credential the lab needs without upgrading to the paid plan, which is
irreversible and makes the account liable for overage.

**The conclusion was wrong, and it was wrong because the question was wrong.** "How do I create an
access key on this account" has no good answer here. "How does this account do programmatic access"
has an excellent one.

## Decision

### Credentials come from `aws login`, and no access key is ever created

```bash
aws login --profile platform-lab      # opens a browser, pick the project
export AWS_PROFILE=platform-lab
```

What that produces:

| | |
|:--|:--|
| Lifetime | **12 hours**, then `aws login --profile …` again |
| Re-grant in a browser | every **90 days** |
| Stored on the laptop | a profile name. **No access key, no secret.** |
| Obtained by | the browser session of the Builder ID that already has MFA on it |

**This is the thing ADR-0018 asked for**, and it is a closer match to
`gcloud auth application-default login` than anything ADR-0023 built: short-lived, browser-obtained,
renewed on demand, with nothing long-lived on disk to leak. The MFA requirement is inherited rather
than engineered — it is on the Builder ID, enrolled 2026-11-04, and the browser flow goes through it.

### ADR-0023 is superseded, and `scripts/aws-bootstrap-identity.sh` is deleted

The script cannot work on this account — IAM console access is blocked and CloudShell does not
start — so leaving it in the repository would be leaving a trap: a careful, well-commented,
stub-tested file that fails three screens into a manual procedure. ADR-0023 is kept, marked
superseded, because **the reasoning is worth more than the artefact** and a repository that quietly
deletes its wrong turns teaches nothing.

What survives from it, unchanged and now in `make aws-guardrails`: reading `sts:GetCallerIdentity`
before doing anything billable, and refusing on a root ARN. That check costs one call and is
correct on any account shape.

### The free plan stays. Do not upgrade.

The page that blocked IAM offers an **Upgrade plan** button, and taking it would have restored IAM,
Identity Center and Organizations. It is also **irreversible**, and it makes the account liable for
pay-as-you-go charges above the credit balance.

**None of that was ever needed.** The free plan blocks IAM; the lab does not need IAM users. The
one thing the paid plan has that is genuinely better — a spend limit that *pauses* resources rather
than merely alerting — remains a real gap, recorded in ADR-0022 Decision 4 and compensated by
`make aws-down` plus `make cost-check`.

## Consequences

**The lesson is the sharpest instance yet of the one this project tracks.** Every earlier case was a
*check* that confirmed a request was recorded rather than that it took effect. ADR-0023 was worse
than that: a **whole design built on documentation describing a different product**, elaborated for
a day, with the first contact with reality deferred to a human step at the very end.

What would have caught it on the first hour: clicking **IAM** in the console. One click, before any
design. The two-days-of-work version of "read the file before editing it".

**It was also found the right way, which is worth recording as the method rather than the luck.**
Three consecutive console pages redirected to the same URL. The first was explained away as an
incomplete signup, the second as a free-plan quirk; by the third the pattern was no longer
deniable — and the question that broke it open was asking what the platform *does* provide instead
of why it was refusing what I wanted.

**`scripts/aws-account-probe.sh` survives and is still worth running**, with its IAM section now
expected to come back denied rather than allowed. What it still answers uniquely: whether an
Organization sits above this account (it does — AWS manages it), whether Budgets is readable (which
ADR-0003's gate requires), which regions are enabled, and **whether `m6a.large` is genuinely offered
in `ap-south-1`** — a pin `clusters/aws/cluster.json` has carried as explicitly unverified since
ADR-0022.

### Correction, measured: the registration page was not noise, and two inferences in this ADR were wrong

The first live run of `scripts/aws-account-probe.sh` settled three things this document had
reasoned its way to instead of asking:

| this ADR said | the API said |
|:--|:--|
| the signup/incomplete page is a free-plan redirect, safe to skip | **`OptInRequired: You are not subscribed to this service`** on every EC2 call |
| AWS manages an Organization above this account | **`AWSOrganizationsNotInUseException`** — it is a standalone account |
| the IAM console being blocked means IAM is unavailable | `iam:ListUsers`, `ListRoles`, `ListVirtualMFADevices` all **succeed** |

**The first one matters most and it was my advice that was wrong.** The registration page says
*"either not finished registering, or your account is currently on free plan"*, and I concluded
free-plan twice — once because credits had been granted and the console worked, once because it
rate-limited. **A working console and a credit balance are not activation.** `OptInRequired` is the
API stating plainly that registration has not completed, and until it does there is no EC2, so no
EKS nodes, so no cluster. Nothing in Module 09 can be built.

**The IAM one changes this ADR's reasoning without changing its decision.** ADR-0023's scheme was
not *impossible* here, only *unnecessary* — `aws login` is still the better credential and no access
key is still the right answer. But "IAM is unavailable" was an inference from three console
redirects, and the API disagrees with it.

**And `aws login` returns `arn:aws:iam::331970435482:root`.** Short-lived (12h) and obtained through
an MFA-protected browser session, which is a materially different thing from a root access key on
disk — but it is still the unrestricted principal, and `make aws-guardrails` currently refuses that
ARN outright. **That guard is now wrong on this account**, and the distinction it needs to draw is
between a root *session* and a root *key*. Parked until there is something to guard.

**What is NOT verified:**

- **That `aws login` exists in the installed CLI.** It is new; an older `aws` will answer
  `invalid choice: 'login'`. This is the first thing to find out and it is one command.
- **That the browser flow works from WSL.** It tries to open a browser inside Linux. WSL usually
  forwards to Windows; if it prints a URL instead, that URL pasted into Chrome does the same job.
- **That a 12-hour credential survives a long `terraform apply`.** It is three times the four-hour
  session ADR-0023 argued for, so the EKS-create case is comfortable — but "comfortable" is an
  inference, and the first `make aws-up` is what tests it.
- **That Terraform's AWS provider reads the profile `aws login` writes.** It is a standard named
  profile, which the provider is documented to read; it has not been seen to.
