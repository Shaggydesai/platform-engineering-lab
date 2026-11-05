# ADR-0003: Cost guardrails for free-tier-only cloud use

**Status:** Accepted
**Date:** 2026-10-17
**Budget:** free tier and promotional credits only. Target steady-state spend: **₹0**.

## Context

Both cloud environments must cost effectively nothing. The danger in a learning project is never
the thing you meant to create; it is the thing you forgot to delete. Verified pricing as of
October 2026:

**Google Cloud / GKE**
- Cluster management fee: **$0.10 per cluster per hour**, all modes.
- GKE free tier: **$74.40 in monthly credits per billing account**, enough to cover the management
  fee of **one zonal Standard or Autopilot cluster**. Credits do not apply to regional clusters and
  do not roll over.
- Nodes are billed separately at Compute Engine rates. Load balancers are billed separately.
- New accounts additionally get a time-limited trial credit.

**AWS / EKS**
- EKS is **not** part of the always-free tier. The control plane is roughly **$0.10 per hour per
  cluster** and is drawn from the credit-based free tier ($100, plus a further $100 for completing
  onboarding tasks).
- Worker nodes, NAT gateways, load balancers, EBS volumes and data transfer are all additional.

These are rounded figures from vendor pricing pages and a community answer; **verify current terms
in the console before creating anything**, because cloud pricing changes and credits expire.

## Decision

### 1. Ephemeral by default

Neither cloud environment is ever left running overnight. Every cloud module ends with `make down`
and a verification that the account shows no running resources. Nothing is "left up to look at
tomorrow".

### 2. The expensive things we simply never create

| Never create | Why | What we do instead |
|:--|:--|:--|
| NAT Gateway | billed hourly *and* per GB, the classic surprise | public subnets with security groups; nodes get public IPs |
| Idle load balancers | billed hourly even with no traffic | NodePort + an elastic/static IP, or create the LB only for the session that needs it |
| Regional GKE clusters | the free credit covers zonal only | zonal cluster, single zone |
| Large or on-demand nodes | the main spend in both clouds | spot/preemptible, smallest size that runs the workload |
| Orphaned disks and snapshots | survive cluster deletion silently | `make down` deletes them; a verification step lists what remains |

### 3. Guardrails before resources

No cloud resource is created in either account until all of these exist:

- AWS Budgets alarm at **$5** with email notification, plus a zero-spend alert.
- GCP budget alert at **₹400** on the billing account, with email at 50%, 90% and 100%.
- Billing export / cost dashboard checked at the start of every cloud session.
- MFA on both root accounts; no root access keys; a dedicated non-root IAM user or service account
  for Terraform.

### 4. The destroy path is a first-class deliverable

`make down ENV=aws` and `make down ENV=gcp` must work, must be idempotent, and must be tested in
the same session the environment is first created. An environment that cannot be destroyed in one
command will not be created.

### 5. A session cannot end without a cost check

The last line of every cloud session's checklist is `make cost-check`, which lists running
instances, load balancers, volumes and clusters in both accounts and fails loudly if anything is
still there.

### 6. Amendment, 2026-11-05: Module 09 runs on an uncredited account, deliberately

This ADR says free tier and promotional credits only. **Module 09 breaks that, on purpose.**

The account created for it (`331970435482`, $100 of credits) has been stuck at
`OptInRequired: You are not subscribed to this service` on every EC2 call since sign-up, with a
support case open. A second, older account (`730335198894`) is fully activated and has **no
credits at all**.

**Measured, not estimated** — `aws ec2 describe-spot-price-history`, ap-south-1, 2026-11-05:

| | $/hr |
|:--|--:|
| 3× `m6a.large` spot (1a 0.0269, 1b 0.0266, 1c 0.0260) | 0.0795 |
| 3× 30 GB gp3 root volumes | ~0.011 |
| 3 public IPv4 addresses — billed since 2024 even when attached | 0.015 |
| one load balancer, only on sessions that need ingress | ~0.023 |
| **total** | **~0.128** |

**≈ ₹11–12/hour, a three-hour session ≈ ₹34, the whole module ≈ ₹100.**

**The argument is not "it is cheap".** It is that **credits hide cost discipline.** This project's
central cost claim is that everything is destroyed at session end and that `make cost-check`
proves it. On a credited account, forgetting `make aws-down` costs nothing anybody notices — the
discipline is simulated. On this one it appears on a card.

That also sizes the alarm honestly. Three nodes and a load balancer left overnight is about
**$1.70**, so **50% of the $5 budget is roughly one forgotten night** — the first threshold fires
the next morning, which is when it is useful. A $50 budget on a credited account would never have
fired at all, and ADR-0022 Decision 2 already notes that an alarm which never fires is
indistinguishable from no alarm.

**What does NOT change.** Decision 2's list is unchanged and now matters more: no NAT gateways, no
idle load balancers, no orphaned disks or snapshots. Decision 3 still requires the $5 alarm before
the first resource, and `make aws-guardrails` enforces it. Decision 5 still means a session cannot
end without `make cost-check`.

**One new rule, from an AWS-specific trap:** an AMI is a standing EBS snapshot charge, so Module 09
does **not** build one. The golden-image scripts run at first boot through cloud-init instead
(ADR-0025), which costs about two minutes per session and nothing at rest.

## Consequences

**Good.** The cloud environments stay free. Teardown automation is forced into existence early,
which is also what makes the environments reproducible.

**Costly.** Every cloud session starts with a few minutes of `terraform apply`. That is the price
of not paying rent on idle infrastructure, and the repetition makes the IaC genuinely solid.

**Risk.** A failed `make down` leaves resources running. Mitigated by `make cost-check` and by the
budget alarms being configured *before* the first resource exists.
