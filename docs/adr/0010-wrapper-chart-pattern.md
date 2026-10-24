# ADR-0010: what a wrapper chart is, exactly

**Status:** Accepted
**Date:** 2026-10-24
**Decides:** the shape every in-cluster component takes, and how one value differs per
environment without duplicating the component.
**Implements:** ADR-0002 Rule 3 ("every in-cluster component is a wrapper chart from the start")

## Context

ADR-0002 Rule 3 exists because the previous attempt installed components with `helm install`,
then tried to put the live releases under Argo CD afterwards. Retrofitting is what cost it weeks.
The rule is therefore "wrapper chart from the start" — but the rule never said what a wrapper
chart *is*, and five components are about to arrive. Five components invented one at a time
become five shapes, and the sixth person to add one copies whichever they found first.

There is also a mechanism to choose. The roadmap asks for `gitops/environments/{onprem,gcp,aws}/`
overlays, and Argo CD offers at least three ways to do that: values files inside the chart,
multiple `sources` with a `$values` reference, or Kustomize over rendered output. Picking by
accident means discovering the limits of the accident later.

Cilium is a useful counter-example and is **not** a wrapper chart: it is Layer 1, installed by
Ansible (ADR-0007, ADR-0008), with its values in `ansible/roles/cilium/files/`. The same is true
of Argo CD. So this ADR governs Layer 3 only — everything the root Application reaches.

## Decision 1 — four files per component, always the same four

```text
gitops/charts/<name>/Chart.yaml                     depends on the upstream chart, pinned
gitops/charts/<name>/Chart.lock                     COMMITTED. pins the dependency's digest
gitops/charts/<name>/values.yaml                    our settings, the ones true everywhere
gitops/environments/<env>/<name>.yaml               the settings that differ per environment
gitops/clusters/<env>/platform/<name>.yaml          the Application that assembles them
```

A wrapper chart contains **no templates of its own** unless the component genuinely needs an
object the upstream chart does not provide — an Issuer, a StorageClass, a NetworkPolicy. When it
does, those go in `templates/` and the reason goes in a comment. A wrapper chart that accumulates
templates is a fork with extra steps.

**Why wrap at all, rather than pointing an Application straight at the upstream chart?** Three
reasons, and the third is the one that matters:

1. Our values live in Git next to the thing they configure, versioned with it.
2. `Chart.lock` pins the upstream *digest*, not just its version — so a re-tagged chart cannot
   change what is deployed.
3. There is somewhere to put the extra objects a component needs. Without a wrapper, those end
   up as a second Application over a directory of loose manifests, and then one component is two
   Applications with no stated relationship — which is how "who owns this object?" becomes
   unanswerable.

**`Chart.lock` is committed, and that is not optional.** Argo CD's repo-server runs
`helm dependency build`, which resolves from the lock file. Without one the sync fails or — worse
— resolves whatever the upstream repository serves today. Regenerating it is a deliberate act:

```bash
make gitops-lock          # helm dependency update for every wrapper chart
```

The lock file changing in a diff is the signal that an upstream version moved. It should be its
own commit, with the reason, like every other pin in this repository.

## Decision 2 — environment values arrive by a multi-source Application

```yaml
spec:
  sources:
    - repoURL: <this repo>
      path: gitops/charts/metrics-server
      helm:
        valueFiles:
          - values.yaml                                              # from the chart path
          - $values/gitops/environments/onprem/metrics-server.yaml   # from the ref below
    - repoURL: <this repo>
      ref: values                                                    # makes $values resolvable
```

The second source has `ref` and no `path`: it is not a source of manifests, only a name that
`$values/...` can resolve against. That is the mechanism Argo CD provides for reading a values
file from outside the chart directory, and it is the reason `environments/` can sit at the top
level rather than inside every chart.

**Rejected: values files inside the chart** (`values-onprem.yaml` next to `values.yaml`). It
works and needs no second source, but it puts every environment's settings inside the component,
so "what differs about GCP?" is answered by opening five charts instead of one directory. The
roadmap asked for the directory for that reason.

**Rejected: Kustomize over rendered Helm output.** More powerful, and the power is the problem:
it can patch anything, so the diff between environments stops being a short list of values and
becomes arbitrary surgery. A values file can only change what the chart chose to expose, and that
constraint is useful.

**The per-environment file may be empty, and often is.** An empty file is better than a missing
one: it makes "this component is configured identically everywhere" an explicit statement rather
than an absence, and adding a difference later does not change the Application.

## Decision 3 — a component wanted everywhere is still declared per cluster

ADR-0009 Decision 2 already settled this: the set of Applications is per cluster. So a component
on all three substrates has three Application files. That is deliberate duplication, and
ApplicationSet is deliberately not used yet — Module 08 revisits it with two real clusters to
compare, rather than now with one and two hypotheses.

The duplication has a limit worth stating: **the Application files differ only in their
environment path and their cluster directory.** Anything else differing — a different chart
version per environment, a different project — means the component is really two components and
should be named as such.

## Decision 4 — sync waves only where there is a real ordering requirement

`argocd.argoproj.io/sync-wave` on the Application, lowest first, and only when the component
genuinely cannot start before another exists:

| Wave | What | Why |
|:--|:--|:--|
| `-10` | CRDs and things everything else needs | cert-manager's CRDs must exist before an Issuer can be validated |
| `0` | ordinary components (the default) | metrics-server, a storage class |
| `10` | things that consume the above | a Gateway needing a working Issuer |

Waves are a cost: they serialise the sync and make a stuck component block everything after it.
So the rule is that a wave is justified by a dependency that *fails without it*, not by a
preference about ordering. If it syncs fine without a wave, it does not get one.

## Consequences

**Good.** Adding a component is a mechanical four-file change, and reviewing one is reading a
`values.yaml` against an upstream chart. `Chart.lock` makes an upstream change visible in a diff.
"What is different about this environment?" is one directory.

**Costly.** Four files for something that could be one Application pointing at an upstream chart.
Three Application files for a component wanted everywhere. The multi-source `ref` is a piece of
Argo CD arcana that has to be learned once.

**Risk.** The pattern is only worth having if it is followed, and the pressure to skip it arrives
with the first component that is "just a ConfigMap". The `gitops-canary` Application is already
an exception — plain manifests, no chart — and its own file says why: it is a test fixture, not a
component. That distinction is the one to defend. If a thing runs in the cluster and other things
depend on it, it is a component, and it gets four files.
