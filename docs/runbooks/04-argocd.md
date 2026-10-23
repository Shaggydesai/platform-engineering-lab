# Runbook: Argo CD and the GitOps seam

**Owner:** Ansible installs it (Layer 2, ADR-0002). Argo CD owns everything below the seam.
**Module:** 04
**Decisions:** ADR-0009 — the seam, the layout, repository access, resource tracking

## What this does

Installs Argo CD and hands it exactly three objects. After this, nothing in the cluster is
installed by hand: adding a component means adding a file and pushing it.

```text
make onprem-up
  └── role: argocd
        helm upgrade --install argocd argo/argo-cd      the Helm release        LAYER 2
        kubectl apply gitops/bootstrap/projects.yaml    2 AppProjects           LAYER 2
        kubectl apply gitops/bootstrap/root-onprem.yaml 1 root Application      LAYER 2
                                      │
                                      ▼                                        LAYER 3
        root Application watches gitops/clusters/onprem/platform/ (NON-recursive)
          └── gitops-canary.yaml ──> gitops/manifests/gitops-canary/
                                       ConfigMap in namespace platform-canary
```

## Run it

```bash
make onprem-up                  # includes Argo CD, or:
make onprem-argocd              # just this role - the repair path

make gitops-status              # what Argo CD thinks, and whether it agrees
make argocd-password            # from the Secret the chart generated, never from Git
make argocd-ui                  # port-forward to http://localhost:8080
```

Confirm the chart version before the first install, the same discipline as Cilium:

```bash
helm search repo argo/argo-cd --versions | head -3
```

If something newer than the pinned `argocd_chart_version` in `clusters/onprem/nodes.json`
appears, move the pin deliberately and record it. Do not let a `helm repo update` decide which
version of the thing that reconciles everything else is running.

## The gate for this module

Two halves, and they test different things.

**A commit changes the cluster, with no `kubectl`:**

```bash
sed -i 's/generation: "1"/generation: "2"/' gitops/manifests/gitops-canary/configmap.yaml
git commit -am 'canary: generation 2' && git push

# within ~60s (timeout.reconciliation in the values file)
kubectl -n platform-canary get cm gitops-canary -o jsonpath='{.data.generation}'; echo
```

**`kubectl delete` on a managed resource is reverted by self-heal:**

```bash
kubectl -n platform-canary delete cm gitops-canary
sleep 20
kubectl -n platform-canary get cm gitops-canary -o jsonpath='{.data.generation}'; echo
```

The second one is the half that matters. Sync proves Argo CD *can* apply Git; self-heal proves
Git is **in charge** — that the cluster is not merely a place where Git's contents were once
copied. Those are different claims, and only the second one makes `kubectl` edits pointless
rather than merely discouraged.

Also run, because it is the enforcement of ADR-0002 Rule 1:

```bash
make gitops-drift
```

## Why it is built this way

**The seam is three objects, and that is a closed set.** ADR-0002 said Layer 2 owns "Argo CD and
only Argo CD", which is unimplementable — an Argo CD with no `Application` does nothing. ADR-0009
names the exception precisely instead of letting it grow: the Helm release, two `AppProject`s,
one root `Application`. Nothing is added there without amending the ADR.

**Argo CD does not manage Argo CD.** `make onprem-argocd` reinstalls it from Ansible at any time,
*including when Argo CD is the broken thing*. The previous attempt at this platform put Argo CD
under its own management before any layer existed that could reinstall it, so when it broke, the
tool that fixes things was the broken thing. Module 11 revisits self-management as a deliberate
exercise, with this path proven first.

**The root Application is non-recursive.** `recurse: true` over a wider path would make Argo CD
manage the wrapper charts' templates directly — the same objects the child Applications manage,
two owners each. Both then report `Synced` while fighting over fields, which is the hardest
GitOps bug to see. One flag turns ADR-0002 Rule 4 from a convention into a structural fact.

**Children carry the finalizer; the root does not.** Deleting the root orphans its children
rather than destroying the platform, and re-applying the file re-adopts them. Recovery has to be
the cheap path.

**`resourceTrackingMethod: annotation`.** Kubernetes label values stop at 63 characters. With
label-based tracking, a long Application name plus a long resource name truncates silently, two
resources look like they belong to one Application, and Argo CD prunes one of them. That is data
loss caused by a string length, and the setting has to be right before anything is managed —
changing it later means re-adopting every resource.

**No repository credential.** The repository is public, so Argo CD reads it anonymously. The URL
is still written into both `AppProject`s, which is what makes adding a credential later a change
to a Secret rather than to every `Application`. ADR-0009 Decision 3 forbids adding a private
repository before Module 07 decides how secrets work — that ordering is the whole point.

## How it breaks

| Symptom | Cause | Fix |
|:--|:--|:--|
| Root app `Unknown`, message about the project | `projects.yaml` was not applied, or applied after the Application | `make onprem-argocd` — the role applies them in order |
| Root app `OutOfSync` forever, nothing happens | `path` does not exist on `targetRevision`, or you have not pushed | `kubectl -n argocd get app platform-onprem -o jsonpath='{.status.conditions}'` |
| A child app is `Synced` but the resource is missing | the resource is outside what its `AppProject` permits | the project denies it silently in the Application's conditions, not in the sync status |
| `ComparisonError: repository not accessible` | the repo URL is not in `sourceRepos`, or the network is blocked | check the project, then `kubectl -n argocd logs deploy/argocd-repo-server` |
| Sync fails with no useful error on a big chart | the repo-server OOMed rendering it | raise `repoServer.resources.limits.memory` in the values file |
| Argo CD pods `Pending` | nothing schedulable — the control plane is tainted and the workers are full | `kubectl -n argocd describe pod`; check worker memory |
| Self-heal does not revert an edit | `selfHeal: false`, or the field is in `ignoreDifferences` | read the Application's `syncPolicy` |
| `make argocd-password` is empty | the initial-admin Secret is deleted once the password is changed | that is expected after a password change; use the one you set |

## Known caveats

**The Argo CD server runs without TLS** (`server.insecure: true`). It is behind a loopback
port-forward today and behind a Gateway that terminates TLS from Module 05, at which point its
own certificate protects nothing and complicates the Gateway. The moment this cluster is
reachable from anywhere but this laptop, that line is wrong.

**`applicationSet` and `notifications` are disabled**, to save memory on a 4 GB control plane.
ApplicationSet arrives in Module 08, when there are two clusters and ADR-0009's "three explicit
files per component" trade is worth revisiting with something real to compare. Notifications
arrive in Module 10 with the rest of observability.

**The admin password lives in `argocd-initial-admin-secret`**, generated by the chart. It is not
in Git and must not be. Module 07 decides how secrets work; until then nothing in this repository
contains one.
