# ADR-0019: the GCP substrate, and what free tier actually permits

**Status:** Accepted
**Date:** 2026-10-31
**Decides:** the shape of the GKE environment, where the cost guardrail lives, how nodes reach
the tenant's images, and how Terraform authenticates. Implements ADR-0003 for GCP.

## Context

Module 08's bar is that the same platform and the same tenant run on GKE from the same Git
repository, and that `make down` leaves nothing billable. ADR-0001 chose three substrates for one
platform; this is the first time that claim gets tested against something other than the laptop.

The seven environment overlays in `gitops/environments/gcp/` have existed since the modules that
created their components. `terraform/gcp/` was an empty placeholder until now.

ADR-0003 set the budget: free tier and promotional credits only, target steady-state **₹0**, with
named things never to create — no NAT gateways, no idle load balancers, no regional GKE clusters,
no orphaned disks.

## Decision

### 1. The guardrail is its own Terraform state, and it is applied first

`terraform/gcp/guardrails/` holds one resource: a ₹400 budget on the billing account, alerting at
50%, 90% and 100%. `make gcp-guardrails` applies it. `make gcp-guardrails-verify` reads it back
out of the API.

**Why a separate state rather than one more resource in the cluster's.** `terraform apply` creates
in dependency order, and nothing would order a budget before a node pool — so a cluster could
exist for the length of an apply, or for the length of a *failed* apply, with no alert watching
it. ADR-0003 Decision 3 says the alarms exist before the first resource; one state cannot express
"before".

The budget is **unfiltered**, covering the whole billing account rather than one project. A filter
restricting it to the project you remembered is silent about the one you forgot, which is exactly
the spend worth catching.

Thresholds use `CURRENT_SPEND`, not `FORECASTED_SPEND`. A forecast alert against a deliberately
spiky lab — a cluster up for three hours, then nothing for a week — fires constantly and teaches
you to ignore it.

### 2. Zonal, spot, two e2-medium nodes

Zonal because the GKE free tier covers the control-plane management fee for **one zonal cluster
per billing account per month** and does not cover a regional one. Regional also triples the
control plane and the node count. The roadmap says zonal only; this is that, with the reason.

`asia-south1-a` (Mumbai) because it is nearest, so `kubectl` and the storefront are responsive.
The trade is spot capacity: if the pool cannot be filled there, the answer is to change the zone
in `clusters/gcp/cluster.json` and re-apply — not to drop spot.

### 3. External IPs on the nodes, because ghcr.io is not a Google service

This is the finding that cost the most to establish and the one most likely to be re-learned
painfully, so it gets its own section.

ShopVerse's seven images live on **ghcr.io**. ADR-0003 forbids NAT gateways. A GKE node with no
external IP and no Cloud NAT cannot reach ghcr.io at all — **Private Google Access covers Google's
own APIs and services and nothing else**, which is the part that reads like it should help and
does not. The failure shape is pods stuck in `ImagePullBackOff` on a cluster that is otherwise
perfectly healthy, with a message about a timeout rather than about egress.

Three options:

| | |
|:--|:--|
| **Cloud NAT** | Forbidden by ADR-0003, and the expensive one — an hourly charge plus data processing |
| **External IPs on nodes** | **Chosen.** No change to the tenant's chart. GCP bills external IPv4 at ~$0.005 per address per hour, so two nodes for a three-hour session is about ₹3 |
| **Mirror into Artifact Registry** | Genuinely ₹0 inside the 0.5 GB free tier, and the better end state. Costs a mirroring step plus a `global.imageRegistry` override in the gcp overlay |

External IPs for the first build, because the point of Module 08 is to prove the platform is
portable, and mirroring images changes the tenant's own references — a second variable in a change
that already has enough.

**This makes the target "₹0 steady-state", not "₹0 ever", and that distinction is now load-bearing
rather than pedantic.** Two lines are non-zero while a session runs: the external IPs above, and
the node disks — the free tier includes 30 GB-months of `pd-standard` and two 32 GB disks exceed
it. Both end when `make down` does. Anything *not* ending with `make down` is a bug, which is what
`make cost-check` exists to catch.

Mirroring to Artifact Registry is parked rather than rejected, and it is the obvious second
session's work.

### 4. Application Default Credentials, never a service-account key file

`gcloud auth application-default login` on the workstation, and no JSON key anywhere in this
repository or on the laptop.

A downloaded service-account key is a long-lived credential sitting in a file — which is precisely
the thing Module 07 spent four stages removing from this project. Reintroducing one for
Terraform's convenience would be the same mistake with a different file name.

### 5. The billing account ID stays out of Git

Everything else about this environment lives in `clusters/gcp/cluster.json`, the same single
source of truth that `nodes.json` is for on-prem (ADR-0008). The billing account ID does not.

It is **not a credential** — knowing one grants nothing — but this repository is public, and it is
the one value here that identifies a payment instrument. It arrives as `TF_VAR_billing_account`.

The cost is that a fresh clone needs one environment variable before the guardrail can be applied.
That is the same honest shape as `.cache/vault-init.json`: reproducible given one thing a human
holds, and said out loud rather than papered over.

### 6. The provider version is pinned by the lock file first, and by this repository second

`terraform/onprem/versions.tf` pins its provider exactly, and its comment explains why a loose
constraint once installed a breaking release. That rule stands.

It is not followed here **yet**, and the reason is recorded rather than hidden: the authoring
environment could not reach `registry.terraform.io` and has no `terraform` binary, so the current
`6.x` patch version could not be read. This project already has `make gitops-check-pins` because
three version pins written from memory were wrong, one of them for a release that did not exist —
guessing a fourth would be choosing to repeat that.

So: a bounded range for the first `terraform init`, which resolves the real version and writes it
with its hashes into `.terraform.lock.hcl`. **The lock file is the actual pin** — Terraform
enforces it on every later init — and it is committed. The exact version then moves into
`versions.tf` in its own commit, read out of the lock file. `make gcp-guardrails` prints that
follow-up so it is a remembered step rather than a hoped-for one.

## Consequences

- **A GCP session has a prerequisite that cannot be automated away:** a project, billing enabled,
  and `gcloud auth application-default login`. Three things a human does once.
- **`make down` is now load-bearing in a way it never was on-prem.** A forgotten `virsh` domain
  costs electricity; a forgotten GKE cluster costs money. `make cost-check` at the end of every
  session is ADR-0003 Decision 5 and it already covers GCP.
- **The free-tier claim gets its first real test.** If the GKE management fee is charged despite
  the cluster being zonal, the budget alert is what reports it, and the right response is to
  record the finding here rather than to keep the cluster running while investigating.
- Nothing in this ADR is verified. No GCP resource exists at the time of writing, `terraform init`
  has never run in this directory, and at least one section above will turn out to be wrong — the
  external-IP cost estimate and the free-tier management-fee assumption being the two most likely.
