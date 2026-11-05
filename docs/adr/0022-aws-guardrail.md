# ADR-0022: the AWS guardrail, and what AWS's free plan changes about the budget

**Status:** Accepted, **with a correction of scope — see the amendment at the end.**
**Date:** 2026-11-03
**Decides:** where the AWS cost guardrail lives, what it is denominated in, why it must name a
recipient, and the two instance-shape facts that have to be settled before a cluster is built.
Implements ADR-0003 for AWS. **Does not decide the EKS cluster** — that is the next ADR, and
writing it now would be recording decisions nobody has made.

## Context

Module 09's bar is the third substrate. ADR-0003 Decision 3 says the budget alarm exists **before
the first cloud resource**, and ADR-0019 implemented that for GCP: a separate Terraform state, a
separate make target, and a verifier that reads the budget back out of the API rather than trusting
that `terraform apply` succeeded.

Porting that to AWS looked like a rename. It is not, and four of the differences change behaviour
rather than syntax.

## Decision

### 1. The guardrail is its own Terraform state, applied first — unchanged from ADR-0019

`terraform/aws/guardrails/` holds one resource: a **$5 monthly COST budget** alerting at 50%, 90%
and 100% of actual spend. `make aws-guardrails` applies it; `make aws-guardrails-verify` reads it
back. The reasoning is identical and is not repeated here: `terraform apply` creates in dependency
order and nothing would order a budget before a node group, so a guardrail applied alongside the
thing it guards is not a guardrail.

**One thing is simpler than GCP.** ADR-0019 records a chicken-and-egg failure: the Cloud Billing
Budget API had to be enabled before Terraform could *refresh* the budget resource, so the resource
that would enable it could never be applied first. AWS has no per-account service enablement, so
that class of failure does not exist. What replaces it is a permissions question —
`budgets:ModifyBudget` and `budgets:ViewBudget` — which on a fresh personal account operating as
the owner is satisfied by default.

### 2. $5 USD, not ₹400, and the currency is a constraint rather than a conversion

An AWS Budget is denominated in the account's billing currency, and a budget in a currency the
account does not bill in is **rejected rather than converted**. ₹400 is about $4.50, so $5 is the
same order of magnitude by coincidence; if the account turns out to bill in INR, the amount and the
currency change together in `clusters/aws/cluster.json`.

**Why the number is small enough to mean something.** An EKS session is roughly **$0.20/hour** (see
Decision 5), so $5 is about 25 hours of cluster time. A budget set at $50 would never fire on a lab
meant to run three hours a week, and an alarm that never fires is indistinguishable from no alarm.

### 3. The budget MUST name a recipient, and the verifier checks that it has one

**This is the difference with teeth.** Cloud Billing emails the billing account's admins by
default, which is why ADR-0019's guardrail can be applied with no notification channel configured
and still reach a human — and why `gcp-guardrails-verify` ends by saying it cannot tell you whether
the email arrives.

**AWS Budgets notify nobody.** A notification with an empty subscriber list is accepted by the API
and silent forever, and it looks correct in the console budget list. So:

- `var.alert_emails` has **no default** and a validation that rejects an empty list.
- The address is taken by `make aws-guardrails` as a **plain string** and wrapped into Terraform's
  `list(string)` there. Exporting `TF_VAR_alert_emails` by hand means writing JSON
  (`'["you@example.com"]'`), and getting that wrong fails inside Terraform with a type error about
  the variable, which reads like a bug in this repository.
- It is persisted to `.cache/aws-alert-email`, mode 600, gitignored — the same arrangement as the
  GCP billing account ID, and for the same reason: this repository is public, and an address in a
  public repository is an address in a scraper's list.
- `scripts/aws-guardrails-verify.sh` makes **three API calls where GCP needs one**:
  `describe-budgets`, `describe-notifications-for-budget` and
  `describe-subscribers-for-notification`. Thresholds are a separate object from the budget, and
  subscribers are a separate object from the thresholds, so a budget with the right amount and no
  notifications — or with notifications and no subscribers — passes any check that stops at the
  first call.

**"Is anyone subscribed" is therefore a failure rather than a caveat**, which is the one place this
script is stricter than its GCP counterpart.

### 4. The free account plan has no spend cap, and ending it suspends the account

Both facts are AWS's, not this repository's, and both change how the guardrail should be read:

| | GCP trial | AWS free account plan |
|:--|:--|:--|
| Credits | ₹28,257, 90 days | $100 at sign-up + up to $100 earned |
| Duration | 90 days | 6 months, or until credits are gone |
| Hard spend cap | no | **no** — the limit that pauses resources requires the paid plan |
| When it ends | billing continues if upgraded | **account and projects are suspended**; 90 days to recover, then permanent deletion |

So on the free plan **this budget is the only guardrail there is, and it alerts rather than stops.**
`make aws-down` is the control; the budget is what tells you it was forgotten. The verifier says
this on every successful run so it does not quietly become invisible.

**The suspension clock is survivable only because of a property this lab already has:** nothing
persistent lives in AWS. Every session is destroyed at its end, and the single standing resource on
the GCP side is one Secret Manager version. A lab that kept state in the cloud would lose it.

### 5. Two instance-shape facts, settled now because one of them is silent

**`m6a.large`, and explicitly not `t3.*`.** The t3 family is **burstable** — a baseline fraction of
a vCPU plus credits — and the Kubernetes scheduler schedules against neither the baseline nor the
credits. That is the same trap as GCP's `e2-medium`, which is listed as 2 vCPU, guarantees one,
reported **940m** allocatable, and made ADR-0016's capacity estimate wrong by **2.05×**: six of
ShopVerse's eight pods stayed `Pending` with `Insufficient cpu`, and MongoDB's PVC stayed `Pending`
behind them.

The failure shape is why this is a pin rather than a measurement: **a burstable node does not fail
at creation.** It creates, reports `Ready`, and then refuses to schedule — so the symptom arrives
one layer away from the cause, inside the tenant's Application.

**Two Availability Zones, and it is not a choice.** EKS requires subnets in at least two AZs to
create a cluster at all, so "zonal EKS" does not exist and there is no cheaper single-AZ shape. The
control-plane fee is per cluster, so the second AZ costs nothing by itself — but cross-AZ traffic
is billed per GB, so **every node is pinned into the first AZ**. The consequence, stated rather than
discovered: this cluster is **not more available** than the zonal GKE one despite having two zones'
worth of subnets, because all of its nodes are in one.

### 6. Public subnets with public IPs, for ADR-0019's reason exactly

ShopVerse's seven images are on ghcr.io. ADR-0003 forbids NAT gateways — at roughly $0.045/hour plus
per-GB processing, a NAT gateway is the most expensive idle object in either cloud — and a node in a
private subnet with no NAT cannot reach ghcr.io. VPC endpoints cover AWS's own APIs and nothing
else, exactly as Private Google Access does.

Mirroring into ECR is the better end state and is parked, as it is parked for GCP, so the two
substrates carry the same debt rather than diverging quietly.

## Consequences

**`make lint` gained two checks, and the second exists because of a near miss in this ADR's own
work.**

1. **A Terraform state whose version constraint is still a RANGE is not required to have a
   committed lock file.** The lock-file check previously failed on any state without one, which
   would have made `make lint` red on a fresh pull for a rule the reader cannot satisfy: a lock
   file can only be produced by `terraform init`, and `terraform/aws/guardrails` was written in an
   environment that cannot reach `registry.terraform.io`. The signal is in the file — a range
   constraint *is* the declaration that init has not run — so **pinning the version exactly is what
   makes the missing lock a failure.** The rule closes itself.

2. **The budget's NAME is checked in both places that write it.** `main.tf` sets the budget name as
   a literal and the verifier looks the budget up *by* that name as a second literal in a second
   file. Rename it in one place and the verifier reports "NO budget named …" about a budget that
   exists and is correct, then sends someone to re-apply a guardrail that applies fine and changes
   nothing — **a false negative on the one gate standing between this repository and a billable
   cluster.** The notification semantics (`COST`, `MONTHLY`, `ACTUAL`, `GREATER_THAN`,
   `PERCENTAGE`) are checked for the same reason: the verifier builds its subscriber-lookup key out
   of three of them, so `FORECASTED` in `main.tf` would make it report "NO subscriber" for every
   threshold of a budget whose subscribers are all present. Both substrates are checked, and all
   three mutations were confirmed to fail the check before it was committed.

**One correction was caught before it shipped, and it is recorded because the draft was confident.**
`outputs.tf` originally instructed the operator to enable the **Receive CloudWatch Billing Alerts**
preference, asserting that cost alerts would not arrive without it. That is false: the preference
governs whether estimated charges are published to CloudWatch as metric data, which is what a
CloudWatch *billing alarm* needs — a different mechanism from AWS Budgets, which emails its
subscribers directly. Checked against AWS's own documentation rather than shipped. The corrected
output now says what the preference actually does and that it is **not** a prerequisite.

**There is deliberately no `aws-up` and no `_aws-preflight` yet.** A gate for a target that does not
exist is dead code, and the gate belongs in the same change as the cluster it refuses to build.
What exists today is the alarm and the check that reads it back, both usable against an empty
account.

**What is NOT verified, and this list is the whole of it, because nothing here has run:**

- **Nothing has been applied.** `terraform` cannot be installed in the environment this was written
  in, so `fmt`, `validate` and `init` are all unexercised; `make lint` runs the first two on the
  laptop. The files were hand-aligned to what `terraform fmt` produces, which is a guess at a
  formatter's output — the kind of guess that has been wrong here before.
- **That `m6a.large` is offered in `ap-south-1`.** Written down as unverified in
  `clusters/aws/cluster.json` with the command that answers it, because three pins in this
  repository have been wrong from memory. The failure is loud and costs one edit — unlike the
  burstable mistake, which is silent.
- **That the account bills in USD.** Decision 2 depends on it and a mismatch is a rejected apply.
- **That the AWS Budgets API accepts a budget name containing spaces.** The GCP budget's
  `display_name` does, and the AWS `BudgetName` is used as a path parameter in two of the three
  verifier calls; if it must be URL-safe, this fails on the first apply and the fix is one string
  in two files — which is now a lint check rather than a hope.
- **That the alert email arrives.** The verifier confirms a subscriber *exists*, which is further
  than the GCP check can get, and an address that bounces still looks identical from the API.


## Amendment, 2026-11-04: this ADR designed the wrong cluster for Module 09's primary path

Found by reading `docs/roadmap.md` while building `docs/reading.md` — that is, by reading the plan,
which nobody had done since Module 08 started.

> **Module 09 — AWS: the self-managed environment**
> Terraform for spot EC2 instances (no NAT gateway); Ansible reused from Module 03 to build the
> cluster; the AWS overlay; **one EKS session for comparison**, then destroyed.

**The primary AWS substrate is kubeadm on EC2**, built by the same `ansible/roles/control_plane`,
`workers`, `cilium` and `kube_proxy_removal` that build the laptop cluster. EKS is **one comparison
session**. This ADR designed EKS as the primary and did not mention kubeadm at all.

**Why that matters beyond tidiness.** GKE already supplied the managed-control-plane contrast that
ADR-0001 asks for; a second managed cluster measures the same axis twice. The self-managed one is
what tests whether **Layers 0 and 1 port** — the Ansible that has only ever run against libvirt VMs
on a laptop. That is the actual question Module 09 exists to answer, and EKS cannot answer it,
because on EKS those four roles have nothing to do.

It is also cheaper by about half: Decision 2's ~$0.20/hour is the EKS figure, and a kubeadm cluster
on plain EC2 has no control-plane fee because the control plane is an instance you are already
paying for.

**What survives unchanged:** the $5 budget and its three thresholds, the subscriber requirement
(Decision 3), the free-plan facts (Decision 4), `m6a.large` over any `t3.*` (Decision 5's real
content), and public subnets with no NAT gateway (Decision 6).

**What does not:** the `node_group` block in `clusters/aws/cluster.json`, which is shaped like an
EKS managed node group; and **Decision 5's claim that two AZs are forced**, which is an EKS
constraint on its control plane and does not bind a kubeadm cluster on plain EC2.

**Put to the user explicitly on 2026-11-05, and answered: kubeadm, with one EKS session for
comparison.** The case for EKS was real and stated — it is what employers use, IRSA is the AWS
answer to Workload Identity and exists only there, and the VPC CNI's max-pods ceiling is a
production constraint Cilium hides. It lost on the measurement: GKE already supplied the
managed-control-plane contrast, and **kubeadm on EC2 is the only thing that tests whether Layers 0
and 1 port** — five Ansible roles that have never run anywhere but libvirt VMs on one laptop. This
is now a decision rather than a default, which is the difference that matters given how the
divergence arose.

**Second instance of this exact mistake.** `STATUS.md` already records one: a parking-lot entry
described something as "Module 08's opening move", and that was believed on a later read when the
roadmap said otherwise. **The roadmap is the plan; a document written later is not an amendment to
it just because it is more recent.** Both times the fix was to go and read the roadmap, and both
times nothing forced that.
