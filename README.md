# platform-engineering-lab

One platform definition, three substrates: a self-managed cluster on-prem, a managed cluster on
Google Cloud, and a self-managed cluster on AWS — all built from this repository, all running the
same workload, all reproducible from nothing in one command.

It exists to be *operated*, not demonstrated. Everything here is installed by GitOps, recovered
from backup, and rebuilt from code on purpose.

```text
                       ┌──────────────────────────────────┐
                       │   this repository (desired state) │
                       └───────────────┬──────────────────┘
                                       │
            ┌──────────────────────────┼──────────────────────────┐
            ▼                          ▼                          ▼
   ┌────────────────┐        ┌──────────────────┐        ┌──────────────────┐
   │  onprem        │        │  gcp             │        │  aws             │
   │  laptop VMs    │        │  GKE zonal       │        │  EC2 spot        │
   │  kubeadm       │        │  managed cp      │        │  kubeadm         │
   │  always-on     │        │  ephemeral       │        │  ephemeral       │
   │  Argo CD lives │        │                  │        │                  │
   │  here          │        │                  │        │                  │
   └────────────────┘        └──────────────────┘        └──────────────────┘
            │                          │                          │
            └──────────── same platform, same app ────────────────┘
                     cert-manager · Gateway API · storage
                     observability · backups · ShopVerse
```

## Status

See **[STATUS.md](STATUS.md)** — current module, what is running, and the next action. It is the
first file to open after time away.

## How this is built

Four layers, with exactly one owner each. This is the central rule of the project and is set out
in [ADR-0002](docs/adr/0002-gitops-ownership-model.md).

| Layer | Owner | Scope |
|:--|:--|:--|
| 0 Infrastructure | Terraform | VMs, networks, cloud clusters, IAM |
| 1 Machine config | Ansible | OS, containerd, kubeadm, kubelet |
| 2 Cluster bootstrap | Ansible | Argo CD, and only Argo CD |
| 3 In-cluster | Argo CD | platform add-ons and applications |

Nothing in Layer 3 is ever installed by hand.

## Layout

```text
docs/
  adr/            architecture decision records - read these first
  runbooks/       one page per component: how it works, how it breaks, how to fix it
  roadmap.md      twelve modules, each with a Definition of Done
  parking-lot.md  problems deliberately deferred
terraform/
  aws/  gcp/      per-environment infrastructure
  modules/        shared modules
ansible/
  inventory/  roles/  playbooks/      layers 1 and 2
gitops/
  bootstrap/      what Ansible applies to get Argo CD running
  platform/       cluster add-ons as wrapper charts
  apps/           workloads (ShopVerse)
  environments/   per-environment value overlays - the only place environments differ
clusters/         per-cluster facts and kubeconfig templates (no secrets)
scripts/          doctor, smoke-test, cost-check
```

## Getting started

```bash
make doctor        # check the workstation has what it needs
make status        # where we are
make help          # everything available
```

Cloud environments are ephemeral and must be destroyed at the end of every session:

```bash
make up   ENV=gcp
make down ENV=gcp
make cost-check    # fails loudly if anything billable survived
```

## Decisions

| ADR | Decision |
|:--|:--|
| [0001](docs/adr/0001-three-substrates-one-platform.md) | Three substrates, one platform definition |
| [0002](docs/adr/0002-gitops-ownership-model.md) | GitOps ownership model — who owns what, decided before anything is installed |
| [0003](docs/adr/0003-cost-guardrails.md) | Cost guardrails for free-tier-only cloud use |
| [0004](docs/adr/0004-onprem-substrate.md) | On-prem substrate and VM sizing — three kubeadm VMs on the SSD |

## The workload

The platform runs [ShopVerse](https://github.com/Shaggydesai/MicroService-App) — a seven-service
Node.js and React e-commerce application. A platform with no workload proves nothing, so the
workload arrives at Module 06, early and deliberately.

## Cost

Target steady-state spend: **₹0**. GKE's free tier covers the management fee of one zonal cluster;
AWS runs on spot instances with no NAT gateway and no idle load balancers. Both environments are
created and destroyed per session. See [ADR-0003](docs/adr/0003-cost-guardrails.md) for the
guardrails, including the budget alarms that must exist before any resource does.
