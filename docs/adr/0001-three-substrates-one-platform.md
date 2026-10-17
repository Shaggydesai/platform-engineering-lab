# ADR-0001: Three substrates, one platform definition

**Status:** Accepted
**Date:** 2026-10-17

## Context

The goal is to learn platform engineering deeply enough to do it professionally, and to have
something a hiring manager can look at. Two failure modes are available:

- **One cluster, learned shallowly.** A single on-prem cluster teaches the mechanics but hides
  everything a cloud provider does for you, and most jobs are on a cloud.
- **Three unrelated tutorials.** Building an on-prem cluster, then an EKS cluster, then a GKE
  cluster as separate exercises teaches three sets of button-clicking and no transferable idea.

The interesting engineering is in the space between them: *the same platform definition, applied to
substrates with very different capabilities.*

## Decision

**One repository defines one platform. Three environments provide it.**

| Environment | Substrate | Kubernetes | Role | Lifetime |
|:--|:--|:--|:--|:--|
| `onprem` | Laptop VMs (substrate chosen in Module 01) | self-managed | Primary home. Argo CD lives here. Where we break things. | always-on |
| `gcp` | Google Cloud | GKE (zonal, managed) | What a cloud does *for* you. Managed control plane, cloud load balancer, cloud storage classes. | ephemeral |
| `aws` | EC2 spot instances | kubeadm (self-managed) | What a cloud does *not* do for you. Same build as on-prem, different network primitives. | ephemeral |

EKS itself is used in two deliberate sessions (Module 09) to compare against the self-managed AWS
cluster, then destroyed. It is not a permanent environment, because its control plane bills hourly
and is not in the always-free tier.

### What stays identical across all three

The platform layer: cert-manager, ingress/Gateway, observability, the Argo CD `Application` set,
and the ShopVerse workload. These live once in `gitops/platform/` and `gitops/apps/`.

### What differs, and is therefore interesting

| Concern | on-prem | GCP | AWS (self-managed) |
|:--|:--|:--|:--|
| Control plane | we run it | Google runs it | we run it |
| LoadBalancer Services | MetalLB | Google Cloud LB | MetalLB or NodePort + EIP |
| Storage class | local-path or Longhorn | `pd-balanced` CSI | EBS CSI |
| Node lifecycle | we patch and reboot | node auto-upgrade | spot interruption |
| Identity | static credentials | Workload Identity | IRSA / instance profile |
| Cost of a mistake | time | money | money |

Those six rows are the entire argument for doing this three ways. Each difference is a thing you
can discuss in an interview with evidence behind it.

Per-environment differences are expressed as values overlays in `gitops/environments/<env>/`, never
by forking the platform definition.

## Consequences

**Good.** Portable platform skills rather than vendor button-clicking. A genuinely strong portfolio
artefact. Every cloud concept has an on-prem counterpart to compare it against, which is how the
concepts stick.

**Costly.** More moving parts than a single cluster, and the overlay mechanism must be set up
early (Module 05) or the environments drift apart.

**Risk.** The cloud environments are ephemeral, so they must be reproducible from Terraform in one
command, or they will quietly stop being used. `make up` and `make down` are therefore Module 08
deliverables, not optional extras.
