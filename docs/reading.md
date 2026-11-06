# Reading

Where to read about the things this lab is made of, in the order the lab meets them.

> **If you want to be taught rather than pointed somewhere, start with
> [`docs/learn/`](learn/README.md).** Those are written chapters — the mechanism explained, then
> what it actually did on this cluster, with the real output and the real mistakes. No tabs
> required.
>
> **This file is the map to primary sources**, for when you want the vendor's own reference with a
> question already in hand. The two are complementary and the order is: chapter, then ADR, then
> the link below.

**Read this repository first, and that is not modesty about the internet.** The ADRs record *why*
each choice was made, what it cost, and — in several cases — what was believed first and turned out
to be wrong. That is the part no vendor documentation contains, because vendor documentation
describes a product working rather than a person learning it. Primary sources are better than this
repository at *what a thing is*; this repository is better at *what happens when you use it here*.

**How to use a row.** Read the ADR first — it is short, and it tells you what question the primary
source is answering. Then read the primary source with that question in hand. Reading in the other
order means reading a reference with no idea which parts matter, which is how a week disappears.

**Primary sources only.** Every link below is the project's or vendor's own documentation. There
are no blog posts and no tutorials, deliberately: this lab has been wrong four times by trusting a
secondary summary, and twice by trusting AWS's own documentation when it described a different
product under the same name (ADR-0024). A document is not a check — the cluster is.

---

## The spine — read these whatever you skip

| Read | Then | For |
|:--|:--|:--|
| ADR-0001, ADR-0002 | [Kubernetes Concepts](https://kubernetes.io/docs/concepts/) | The ownership model everything else obeys. ADR-0002 Rule 3 ("nothing in Layer 3 is installed by hand") is the rule this project breaks least and benefits from most. |
| ADR-0009, ADR-0010 | [Argo CD docs](https://argo-cd.readthedocs.io/), esp. *Declarative Setup* and *App of Apps* | Why there is a `clusters/` directory and an `environments/` directory and they are not the same thing. The wrapper-chart pattern in ADR-0010 is what makes one chart serve three substrates. |
| ADR-0003 | your cloud's billing console | The only ADR with money attached. Read it before any cloud session, not after. |

## Phase 1 — the substrate (Modules 00–04)

| Read | Then | For |
|:--|:--|:--|
| ADR-0004, ADR-0006, runbook 01 | [libvirt](https://libvirt.org/docs.html), [cloud-init](https://cloudinit.readthedocs.io/) | Why the VMs are libvirt rather than VMware, and why `/tmp` losing a cloud-init ISO makes `make onprem-vms` noisy forever (parking lot, 2026-10-26). |
| ADR-0005 | [WSL docs](https://learn.microsoft.com/en-us/windows/wsl/) | Why the repo must never live under `/mnt/c`. |
| ADR-0008, runbook 03 | [Ansible docs](https://docs.ansible.com/ansible/latest/) — *Playbooks*, then *Roles* | The distinction this project cares about: Ansible **asserts** what the image already did rather than configuring from scratch. Also where `retries: N` means N total attempts, which cost a wrong comment. |
| ADR-0007, ADR-0012 | [Cilium docs](https://docs.cilium.io/) — *kube-proxy replacement*, *eBPF datapath* | The single most educational pair here. `cilium-dbg service list` is the authority, **not** `iptables-save` — a check that reads the wrong tool answers a different question than the one asked. |
| runbook cluster-bootstrap | [kubeadm](https://kubernetes.io/docs/reference/setup-tools/kubeadm/) | What `kubeadm init` actually does, once, by hand, before Ansible hides it. |

## Phase 2 — the platform (Modules 05–07)

| Read | Then | For |
|:--|:--|:--|
| ADR-0011 | [cert-manager](https://cert-manager.io/docs/) — *Issuers*, then *Certificate* | Why this lab has a private CA and no ACME, and why "everything presenting a certificate got it from `platform-ca`" is still false in three places (parking lot). |
| ADR-0013, ADR-0014 | [Gateway API](https://gateway-api.sigs.k8s.io/) — *API types*, then *Implementations* | **Read the spec, not a vendor's version of it.** The same `HTTPRoute` object runs unchanged on Cilium and on a Google ALB here. `sectionName` is the field worth understanding: without it a route attaches to every compatible listener, including plain HTTP. |
| ADR-0015 | [Kubernetes Storage](https://kubernetes.io/docs/concepts/storage/) — *PV*, *StorageClass*, *volumeClaimTemplate* | `WaitForFirstConsumer` explains a Pending PVC that is actually a Pending pod. And a StatefulSet's PVC is owned by nothing in Git, which is how a disk survived a clean teardown (ADR-0021). |
| ADR-0016 | [Helm docs](https://helm.sh/docs/) — *Chart template guide*, *Values* | Onboarding a tenant end to end. Also the capacity arithmetic that was wrong by 2.05×, which is really a lesson about reading machine types. |
| ADR-0017 | [NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/) | Note what it *cannot* express — the "allow the ingress layer in" rule is the one that cannot be written once for three substrates. |
| ADR-0018, runbook 07 | [Vault](https://developer.hashicorp.com/vault/docs) — *Kubernetes auth*; [External Secrets](https://external-secrets.io/) | The longest ADR and the one with the most consequences. `ClusterSecretStore` is one identity for a whole cluster, which is fine at one tenant and wrong at two. |

## Phase 3 — portability (Modules 08–09)

| Read | Then | For |
|:--|:--|:--|
| ADR-0019, ADR-0020 | [GKE docs](https://cloud.google.com/kubernetes-engine/docs) — *Dataplane V2*, *Workload Identity* | Dataplane V2 is managed Cilium, which is why NetworkPolicy is *enforced* rather than merely accepted — and it cannot be changed in place. Workload Identity replaces a key file entirely. |
| ADR-0021 | [GKE Gateway controller](https://cloud.google.com/kubernetes-engine/docs/concepts/gateway-api) | What a Gateway creates that Terraform never made — and therefore what `make gcp-down` must delete *before* the cluster. Read the correction section too; it is three wrong diagnoses in a row. |
| ADR-0022, ADR-0024 | [EKS docs](https://docs.aws.amazon.com/eks/latest/userguide/), [AWS Budgets](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html) | EKS has no free tier and cannot be zonal. ADR-0024 is worth reading as a cautionary tale rather than a design. |
| — | [Terraform](https://developer.hashicorp.com/terraform/docs) — *State*, *Providers*, *Dependency lock file* | **Read the State page properly.** Terraform writes every managed attribute into state in plaintext, and `sensitive` suppresses output, not state — which is why `terraform/gcp/secrets` deliberately contains no secret *version*. |

## Phase 4 — not built yet (Modules 10–12)

Read these when the module arrives, not before — reading a reference for something you are not
about to build is how enthusiasm gets spent before the work starts.

[Hubble](https://docs.cilium.io/en/stable/observability/) · [Prometheus](https://prometheus.io/docs/)
· [OpenTelemetry](https://opentelemetry.io/docs/) · [Sigstore](https://docs.sigstore.dev/)

---

## The parking lot is the best thing in here

`docs/parking-lot.md` is not a TODO list. It is a record of **problems deliberately deferred and
mistakes made**, each with what was believed, what was true, and what it cost. Several entries are
about checks that passed while the thing was broken — the failure shape this project exists to
notice.

If you read one file in this repository for the engineering rather than the technology, read that
one. It is the only document here where every entry was paid for.

## And the code comments are not decoration

`scripts/gcp-smoke.sh`, `scripts/cost-check.sh` and the chart templates carry their reasoning
inline, including the wrong version where a wrong version existed. A comment saying *"the first
version of this check counted objects and called them attached"* is worth more than the check.
