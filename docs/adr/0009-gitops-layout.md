# ADR-0009: the GitOps seam, the Application layout, and repository access

**Status:** Accepted
**Date:** 2026-10-23
**Decides:** exactly which in-cluster objects Ansible owns, how Git is laid out so that two paths
can never render the same object, and how Argo CD authenticates to this repository.
**Amends:** ADR-0002, Layer 2 ("Argo CD itself, and only Argo CD")

## Context

ADR-0002 was written before any of this existed and says Layer 2 owns "Argo CD itself, and only
Argo CD". Taken literally that is unimplementable: an Argo CD with no `Application` does nothing
at all, so *something* has to create the first one. The previous attempt at this platform never
resolved that and ended up with Argo CD managing its own installation — which removed the
recovery path at exactly the moment it was needed.

Three things therefore need deciding before a single role is written, because deciding them late
is how the last attempt lost weeks.

## Decision 1 — the seam is a closed set of three objects

**Ansible applies `gitops/bootstrap/` and nothing else in the cluster. Argo CD owns everything
below it.**

```text
Layer 2  Ansible    the Argo CD Helm release
                    gitops/bootstrap/projects.yaml      2 AppProjects
                    gitops/bootstrap/root-onprem.yaml   1 root Application
                    ───────────────────────────────────────────────────────
Layer 3  Argo CD    everything the root Application points at, recursively
```

That is **three objects plus the Helm release**, and the rule that keeps it honest:

> Nothing is added to `gitops/bootstrap/` without amending this ADR.

The AppProjects are in the seam rather than under Argo CD because an `Application` referencing a
missing project is rejected, so they must exist first; putting them under the root app would be a
dependency cycle solved with sync waves, which is complexity bought for nothing.

ADR-0002's Rule 2 — *Argo CD does not manage Argo CD* — is unchanged and is the point of all
this. `make onprem-up` reinstalls Argo CD from Ansible at any time, including when Argo CD is the
broken thing.

**The root Application carries no finalizer; children do.** Deleting the root app therefore
orphans its children rather than destroying the platform: the children keep running, and the next
sync re-adopts them because they are still in Git. Deleting a *child* does remove its resources.
This is deliberate — ADR-0002's stated risk is that Layer 2 is the single point of failure for
recovery, so recovery must be the cheap path and a mis-typed `kubectl delete app` must not be an
outage. The cascading version is a drill for Module 11, done on purpose.

## Decision 2 — one directory per cluster, charts kept out of the sync path

```text
gitops/
  bootstrap/                      ANSIBLE OWNS THESE THREE FILES
    projects.yaml
    root-onprem.yaml
  clusters/
    onprem/platform/              child Applications for this cluster, one per component
      gitops-canary.yaml
    gcp/platform/                 Module 08
    aws/platform/                 Module 09
  charts/                         wrapper charts (Module 05+). NOT in any sync path.
  manifests/                      plain manifests that have no upstream chart
    gitops-canary/
```

Two rules make overlap impossible, which is ADR-0002 Rule 4 made concrete:

**The root Application is non-recursive and reads only `*.yaml` in one directory.** With
`recurse: true` over `gitops/` it would also find the wrapper charts and try to manage their
contents directly — the same objects the child Applications manage, with two owners each. That
failure is subtle: both Applications report Synced while fighting over fields.

**Charts and manifests live outside every cluster directory.** A child Application *points at*
`gitops/charts/x`; nothing syncs that path as a directory of manifests. The separation is
structural rather than a convention to remember.

**One directory per cluster, not one set of overlays.** The roadmap's Module 05 asks for
`environments/{onprem,gcp,aws}` overlays, and that is still how *values* differ — a chart plus a
per-environment values file. But the **set of Applications** is per cluster, because the clusters
genuinely differ in what runs on them: a storage class on-prem, a managed one on GKE. Adding GCP
in Module 08 is then a new directory and a new root Application, with nothing shared to break.

## Decision 3 — no repository credential, deliberately and temporarily

This repository is **public**, so Argo CD reads it anonymously. No credential is created, stored
or configured, which is the correct answer today and worth stating rather than leaving implicit.

What must not happen is the obvious shortcut when that changes: a deploy key or token pasted into
a Secret and applied by hand, becoming a thing that exists in exactly one cluster and in nobody's
notes. So the decision has a second half:

> When this repository becomes private, or a second private repository is added, Argo CD's
> credential is created by the mechanism Module 07 chooses for secrets, and by no other means.
> Until Module 07 exists, no private repository is added.

The repository URL is written explicitly in each `AppProject`'s `sourceRepos` even though access
needs no credential. That is what makes adding one later a change to a Secret rather than a change
to every `Application`.

## Decision 4 — resource tracking by annotation, not label

`application.resourceTrackingMethod: annotation` in the Argo CD ConfigMap.

The default in older versions tracked ownership with a label, and Kubernetes label values are
limited to 63 characters. A long `Application` name plus a long resource name silently truncates,
two resources end up looking like they belong to the same Application, and Argo CD prunes one of
them. Annotations have no such limit. This is a one-line setting that prevents a data-loss bug,
and it has to be set before anything is managed, because changing it later means re-adopting
every resource.

## Consequences

**Good.** The question "who owns this object?" has a mechanical answer: if it is one of three
files in `gitops/bootstrap/`, Ansible; otherwise Argo CD. Recovery from a broken Argo CD is
`make onprem-up`, tested on every run. Adding a cluster adds a directory.

**Costly.** A new platform component needs two files — a wrapper chart and an `Application` in
each cluster directory that should run it. Per-cluster Application sets mean a component wanted
everywhere is declared three times. `ApplicationSet` exists to collapse that and is deliberately
not used yet: three explicit files are more legible than one generator while the shape is still
being learned, and Module 08 is the right moment to revisit it with two real clusters to compare.

**Risk.** The seam is only as good as the rule protecting it. The failure mode is somebody - me -
applying "just one more" manifest with `kubectl` during debugging and leaving it there. ADR-0002
Rule 1 already forbids that; this ADR adds the detectable version: anything in the cluster that
is neither in `gitops/bootstrap/` nor owned by an Argo CD `Application` is a bug, and that is a
query, not an opinion.
