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

## Consequences

**Good.** The cloud environments stay free. Teardown automation is forced into existence early,
which is also what makes the environments reproducible.

**Costly.** Every cloud session starts with a few minutes of `terraform apply`. That is the price
of not paying rent on idle infrastructure, and the repetition makes the IaC genuinely solid.

**Risk.** A failed `make down` leaves resources running. Mitigated by `make cost-check` and by the
budget alarms being configured *before* the first resource exists.
