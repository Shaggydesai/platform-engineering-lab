# ADR-0016: onboarding a tenant

**Status:** Accepted
**Date:** 2026-10-29
**Decides:** where a tenant's chart lives, how its Application reaches the cluster, and what the
`tenants` boundary turns out to forbid. Amends ADR-0009 (the seam is now three objects).

## Context

ShopVerse is the platform's first tenant: a seven-service Node.js and React application with
MongoDB, in [its own repository](https://github.com/Shaggydesai/microservice-app), which already
carries a complete Helm chart.

Module 05 closed with five platform Applications Synced and Healthy. The `tenants` AppProject has
existed since Module 04 and has never been used, so every restriction in it is currently an
assertion rather than a tested fact.

## Decision

### 1. The chart stays with the application

The Application renders `helm/shopverse` from the app's own repository over a git source. The
platform does not vendor its tenant's code.

This is the same mechanism as local-path-provisioner for an entirely different reason: there, the
chart had no Helm repository to come from; here, it has no business living in the platform repo.
What this repository owns is *where* ShopVerse runs and *with what settings* — one Application
file and one values overlay.

Pinned to commit `d3cfecb3aeb14a9d2db167fec24ae9cb100a2703`, because the repository has no tags.
That is **stronger** than the local-path pin, not weaker: a commit cannot be moved, so there is no
re-tag for `make gitops-check-pins` to detect.

### 2. A second root Application — and it is in the `platform` project

The platform root reads `gitops/clusters/onprem/platform/` with recursion off (ADR-0002 Rule 4),
so there is no way to add a sibling directory to it, and a tenant workload has no business
sharing a directory with a platform component. Hence `root-tenants-onprem.yaml` over
`gitops/clusters/onprem/apps/`.

**The subtle part:** that root is in the `platform` project, not `tenants`. It creates
Application *objects* in the `argocd` namespace, and the whole point of the tenants project is
that its destinations are restricted to `shopverse-*` — so a tenants-project root could not
create the very Applications it exists to create.

So the boundary sits one level down, which is where it belongs. The root is platform-owned
plumbing; what it deploys is tenant-owned. Getting this wrong produces a root Application that
reports a destination violation and looks like a typo.

### 3. The seam is now three objects

ADR-0009 Decision 1 said Ansible applies the seam and that nothing may be added to it without
amending that ADR. This is the amendment: `projects.yaml`, `root-onprem.yaml`,
`root-tenants-onprem.yaml`. Order still matters — an Application referencing a missing project is
rejected, so `projects.yaml` stays first.

### 4. What the tenants boundary actually forbade

Two restrictions decided settings before anything was deployed, which is the best possible
outcome for a boundary written two modules early:

**`networking.k8s.io/NetworkPolicy` is blacklisted inside the tenant's own namespace**, so
`networkPolicy.enabled: false`. The chart ships policies and the tenant may not create them. That
is deliberate — a tenant that writes its own network policy can write one that opens itself up —
and it means the platform must supply them instead.

**It now does — ADR-0017**, written from a graph Hubble observed rather than from the chart's
defaults, and proven by denying a pod that differs from an allowed one by a single label.

The chart's policy would also have been wrong here: it allows ingress from a namespace labelled
`ingress-nginx`, and traffic will arrive from Cilium's Envoy, which is not that. The correct
selector cannot be established without the traffic existing first, so the platform-side policies
come after the app runs and get verified by breaking them.

**Destinations must match `shopverse-*`**, so the namespace is `shopverse-prod`. Checked rather
than assumed: a destination outside the pattern is rejected with exactly the `Unknown/Unknown`
that the storage Application produced when its repository was not listed.

Everything else the chart creates is namespaced and permitted — Deployments, Services, a
StatefulSet, a Secret, a ServiceAccount, ConfigMaps. So the tenant fits inside the box, and that
is now a fact rather than a hope.

### 5. Ingress off, because this cluster has no Ingress controller

`ingress.enabled: false`. Not a preference: there is no nginx here. Ingress is Gateway API served
by Cilium (ADR-0013, ADR-0014), and an `Ingress` object would be created, accepted, and silently
serve nothing — the worst failure shape available.

The route arrives separately as an HTTPRoute, and note what that means: **the tenant cannot give
itself a hostname.** The Gateway and its listeners are platform-owned, so a name on it is
something the platform grants. That is a property worth having rather than an inconvenience.

### 6. Secrets: generated in-cluster, out of band, and time-boxed

The chart's default is `secrets.create: true` with `change-me-jwt-secret` and `admin123` sitting
in `values.yaml`. Correct for a demo; wrong here for one specific reason — those values would be
in Git.

So `make shopverse-secret` generates six random hex values and applies them as
`shopverse-credentials`, and the chart consumes it by name. Hex because `mongo-password` is
embedded in a connection string and must be URL-safe.

**This is a deliberate exception to ADR-0002 Rule 3** ("nothing in this cluster is installed by
hand"), and it is the honest shape of the problem rather than a shortcut. The credential exists in
the cluster and nowhere else: not in Git, not in this repository, not in a file. Module 07 is
where secrets get solved properly and the chart already supports External Secrets for exactly
that path.

The target **refuses to overwrite an existing Secret**, and that refusal is load-bearing:
`mongo-password` initialises the MongoDB root user on the volume's first boot only. Replacing it
later leaves the database expecting the old one, and every service then fails to authenticate
against a Mongo that is running and reporting healthy — which reads like a connection-string bug
for about an hour. Rotating deliberately means deleting the volume too, and the target prints
those commands.

### 7. The default StorageClass is used by not naming one

`mongodb.persistence.storageClass: ""`, so the PVC takes `platform-local` (ADR-0015). Letting the
default apply is the entire reason it is marked default; a chart that names a class has the
platform's implementation baked into it.

5Gi of a 35Gi worker disk, node-local. ADR-0015's warning applies in full and should stay
uncomfortable: lose that node and the orders are gone.

## Outstanding — resolved 2026-10-30

**`global.imageTag` was `latest`.** Now `sha-6fd8524`, identified by digest rather than by
choosing a plausible-looking tag, and confirmed across all seven services against what their pods
were actually running. The details are in
`gitops/environments/onprem/shopverse.yaml`, where whoever changes it next will read them.

Two things learned in the doing, both recorded in `scripts/gitops-check-pins.sh`:

**Pinning an image rolls the workload, even when the bytes are identical.** I predicted the
opposite — that no pod would restart because all seven were already on those digests — and the
ReplicaSets disproved it within the hour. Kubernetes rolls a Deployment on the image **string**,
not on the digest that string resolves to, so `:latest` → `:sha-6fd8524` changes the pod template
hash and replaces every pod.

What survives of the point I was making: the bytes did not change, so the rollout carried no new
code and could not have introduced a regression. That is still worth distinguishing from a pin
that also upgrades. But it is a rollout, it cost the ~9 seconds of 502s per service measured
above, and anyone pinning an image in a live system should expect one.

**An empty digest is never a match.** A first attempt at the comparison had no guard against
failed lookups and reported all eight candidate tags as identical to `latest` — when in fact
every request had failed and it was comparing `""` to `""`. Eight matches that meant "both sides
were empty". The guard now in `check-pins` exists because of that, not in anticipation of it.

## Consequences

- Three Applications in the platform project create objects in other projects' namespaces, which
  is fine and worth saying once: the project boundary constrains the Application, not the
  directory it was read from.
- `make shopverse-admin` reads the admin login back out of the cluster, the same way
  `make argocd-password` does, so the value never needs to be printed at creation time.
- Nothing is verified. This ADR is written before the first sync, and the sections above will be
  wrong in at least one place.

---

## Verified, 2026-10-29

`make shopverse-check` against `https://shopverse.platform.local`:

```
1/7  GET /                     -> 200     (CA verifies; no -k anywhere)
2/7  GET /api/products         -> 200     20 products; "Atomic Habits"
3/7  POST /api/users/register  -> 201     token issued
4/7  POST /api/cart/items      -> 201     1 line
5/7  POST /api/orders          -> 201     SV794262878409, total 439
6/7  delete shopverse-mongodb-0          back Ready on k8s-w01 (was k8s-w01)
                                          same PersistentVolume: pvc-3a7105d5-…
7/7  GET /api/orders/SV794262878409      attempt 1: 502 … 2: 502 … 3: 502 … then 200
```

Most of this ADR survived contact. Three things it got right that were not obvious, and one new
finding that matters more than any of them.

**The tenant fits inside its box.** Eight pods, a StatefulSet, a Secret, Services and a
ServiceAccount, all created under a project that forbids every cluster-scoped resource. Section 4
predicted this; it is now a fact.

**The default StorageClass was taken by not naming one**, and the volume survived the pod being
deleted — same PV, same node, which is what node-local means (ADR-0015). The script asserts the
PV is unchanged rather than only that the order is readable, because "the order is still there"
would also be true of a pod that returned with an empty volume and an order recreated by
something else.

**The route points at the frontend and that was sufficient**, as section 5 argued: `/api/products`
traverses nginx → api-gateway → product-service → MongoDB on one route, and the checkout call
alone crossed five of the seven services.

### The nine-second window

Steps 7's three `502`s are a measured property of this platform, not noise.

After MongoDB's pod is deleted, the **services report healthy while being unable to serve**. The
api-gateway returns 502 for roughly nine seconds — three retries at three-second intervals — and
during that window a real customer gets an error page, not a slow response.

MongoDB itself came back in seconds; the delay is the Node.js services re-establishing their
connections. Their readiness probes pass throughout, because they answer `/readyz` from the
process rather than from the database. So Kubernetes keeps sending traffic to pods that cannot
complete a request, which is correct behaviour given what it was told and the wrong outcome.

This is squarely **Module 11 (Resilience)** material and it is the application's concern rather
than the platform's, so nothing here changes. But the number is now measured rather than
imagined, and it belongs next to ADR-0013's ~15 seconds of ingress failover: losing a node costs
about 15 seconds of ingress, and losing the database pod costs about nine seconds of 502s. Both
were invisible until something deliberately broke them.

## Amendment, 2026-11-01 — the same tenant on GKE

ADR-0016 onboarded ShopVerse onto the laptop and claimed the arrangement would port. This is what
porting it actually cost: **one Application, one overlay, one seam file, and one line in an
inventory.** Nothing in the tenant's own chart changed, and nothing in the `tenants` AppProject
changed.

### Four values differ, and two of them are the same text

Read `gitops/environments/gcp/shopverse.yaml` beside the on-prem one. The structure is identical
and four values differ — but only two differ *visibly*:

| | on-prem | gcp | why |
|:--|:--|:--|:--|
| `externalSecret.remoteKey` | `shopverse/prod` | `shopverse-prod` | Secret Manager IDs forbid the slash |
| `secrets.existingSecret` | `shopverse-credentials` | *empty* | nothing to roll back to here |
| `ingress.enabled` | `false` | `false` | **same value, opposite reason** |
| `mongodb.storageClass` | `""` | `""` | **same value, different meaning** |

**Those last two are the argument for writing overlays as values with reasons rather than as
diffs.** Half the differences between these substrates would not appear in a diff at all.

### Ingress off: the same line is a no-op on one substrate and a standing charge on the other

On-prem, `ingress.enabled: false` is there because an Ingress object would do **nothing** — that
cluster has no Ingress controller, ingress is Gateway API served by Cilium (ADR-0013/0014), and
the object would be created, accepted, and silently serve no traffic.

On GKE it is there because an Ingress object **would work**. GKE has a built-in ingress
controller, and an Ingress here provisions a Google HTTP(S) load balancer billed by the hour from
the moment it exists, whether anyone visits the storefront or not.

**A failure that works is harder to catch than one that does not.** `enabled: true` on this
substrate would succeed: Argo CD reports Synced and Healthy, the storefront serves, and the bill
arrives monthly. ADR-0003 forbids *leaving* a load balancer running, not creating one — so a
cloud LB raised for a session and destroyed with `make gcp-down` is entirely within the rules.
That is a deliberate next step, not a prohibition.

### Storage: the identical value, and the clearest thing the cloud buys

`storageClass: ""` means "use the cluster's default" on both, and letting the default apply is
the principle both follow — a chart that names a class has the platform's implementation baked
into it. What the default *is* differs entirely:

- **on-prem** `platform-local`, a directory on one worker's disk. Lose that node and the data is
  gone (ADR-0015), a warning that is supposed to stay uncomfortable.
- **gcp** `standard-rwo`, a Persistent Disk. A *network* device: it detaches from a failed node
  and reattaches elsewhere, and the pod moves with its data.

That single property is most of what people mean by "cloud native storage", and it is the
clearest thing this substrate buys that the laptop cannot have at any price. It is also why
`gitops/environments/gcp/local-path.yaml` deploys nothing — the component whose entire job is
dynamic provisioning has no counterpart where the provider ships one.

### What did not need touching — and the one thing that did

The `tenants` AppProject travelled unedited. Its destinations name `shopverse-*` and
`https://kubernetes.default.svc` — the address a cluster uses for *itself* — so cluster-scoped
resources stay forbidden, and `ResourceQuota`, `LimitRange` and `NetworkPolicy` stay forbidden
even inside the tenant's own namespace. A boundary written about Argo CD rather than about a
laptop turns out to be portable.

### Three things this does not establish, and one of them is uncomfortable

**It has never run.** The tenant is deployed by a seam that rests on an External Secrets
arrangement no cluster has exercised (ADR-0018's amendment lists its four unknowns). If the
overlay's `serviceAccount.annotations` path does not reach the subchart, Workload Identity is
simply off, the Secret is never written, and every tenant pod stays Pending — so **a single
unproven link invalidates this whole amendment, not part of it.** `make gcp-smoke` checks the
store and the Secret *before* it looks at pods, so the output distinguishes the two.

**The storefront is not known to serve.** `make shopverse-check` — register, cart, checkout,
delete MongoDB, confirm the order survived — runs over HTTPS through the on-prem Gateway with the
platform CA. There is no Gateway here and no ingress, so that check has no GCP counterpart and
the tenant is reached by port-forward. Proving the order lifecycle on GKE is part of the ingress
decision, not separate from it.

**Capacity is an estimate.** Two e2-medium spot nodes give roughly 3.8 allocatable vCPU and
5.6 GiB across the pair, carrying Argo CD, cert-manager, External Secrets, GKE's system pods and
Dataplane V2's agent, and then eight tenant pods. The arithmetic says it fits. An estimate is not
a measurement, and `Pending` is what a wrong one looks like — which is also what a missing Secret
looks like, hence the ordering above.

> **Measured 2026-11-02: that estimate was wrong by 2.05×, and the paragraph above is left
> standing because the way it was wrong is the lesson.**
>
> ```
> allocatable   940m x 2 = 1880m          (estimated 1930m x 2 = 3860m)
> requested     939m (99%) + 931m (99%)
> headroom      10m
> ```
>
> Six of eight tenant pods stayed `Pending` with *"0/2 nodes are available: 2 Insufficient cpu"*,
> and MongoDB's PVC stayed `Pending` behind them because GKE's default StorageClass is
> `WaitForFirstConsumer` — a consequence, not a second fault.
>
> **The arithmetic was fine. The input was not.** `e2-medium` is a **shared-core** machine type:
> listed as 2 vCPU, with **one guaranteed** and the second as burst — and the scheduler does not
> schedule against burst capacity. So GKE reports 940m allocatable, and "2 vCPU × 2 nodes" was
> never the number. Memory was never the problem: 76% and 68%.
>
> The nodes are `e2-standard-2` now (2 dedicated vCPU, ~1930m allocatable). What was deliberately
> **not** done is shrinking the tenant's requests to fit: that makes the workload fit the cluster
> rather than the cluster fit the workload, and ends with everything BestEffort and nothing
> predictable. The tenant stays the same chart at the same commit on both substrates, because that
> is the measurement.
>
> **And the comparison worth keeping:** on-prem is 3 × 2 **dedicated** vCPU from libvirt, about
> 6 vCPU of schedulable capacity. The GKE cluster had 1.88. **The laptop was bigger than the
> cloud** — which is not an argument about clouds, it is an argument about reading the machine
> type rather than the marketing number.

## Correction, 2026-11-01 — a tenant may not create its own namespace

The amendment above said the `tenants` AppProject travelled unedited and left it there. It did
travel unedited — and on the tenant's first sync on GKE it did its job:

```
one or more synchronization tasks are not valid:
resource :Namespace is not permitted in project tenants
```

The Application carried `CreateNamespace=true`. **A Namespace is cluster-scoped, and the `tenants`
project blacklists every cluster-scoped kind by design** — a tenant that can create cluster-scoped
objects is not a tenant. So the project was working exactly as written, and the Application had
been asking for a permission a tenant should never have.

### It had never failed on-prem, and that is the finding

`shopverse-prod` already existed there. `make shopverse-secret` created it in Module 06 by
applying a Secret into it, before Argo CD ever needed the namespace — so `CreateNamespace=true`
was a no-op for five modules and the restriction never had anything to reject.

**A manual step was masking a design error, and removing the manual step is what found it.** The
manual step was itself the thing the GCP secret backend replaced: on GKE the credentials come from
Secret Manager through Workload Identity, so nothing touches the cluster by hand, so nothing
created the namespace first.

It also means the on-prem cluster was wrong the whole time in a way nobody could see: **it has a
namespace that is not in Git and not managed by Argo CD** — a quiet violation of ADR-0002 Rule 3
("nothing in Layer 3 is ever installed by hand"). A namespace is invisible once it exists. There
is no symptom to notice.

### The fix is not "allow Namespace in the tenants project"

That would have made the error go away and the design worse. The correct answer is the one this
ADR already applies to hostnames: *the tenant cannot give itself a name on the Gateway, because
the Gateway is platform-owned and a name on it is something the platform grants.* **A namespace is
the same kind of thing, and more so — it is the boundary every other tenant restriction is written
against.**

So the namespace is a platform-owned manifest:

- `gitops/manifests/tenant-namespaces/shopverse-prod.yaml` — shared by every substrate, like the
  canary. A namespace name is not a substrate difference.
- `gitops/clusters/<substrate>/platform/tenant-namespaces.yaml` — an Application in the
  **`platform`** project, which does permit cluster-scoped resources. Sync wave **-20**, ahead of
  cert-manager's -10, which was chosen to "leave room for something that must precede even
  cert-manager". This is that something.
- `CreateNamespace=true` removed from **both** tenant Applications. The on-prem one had been
  asking for a permission it should not have since Module 06; it simply never needed it.

**On-prem, the first sync is an adoption rather than a creation.** The Application reports
OutOfSync, adds the labels, and goes Synced; nothing inside the namespace is touched, because
applying a Namespace changes metadata and nothing else. After that, Git describes it.

### Two deliberate exceptions, both the opposite of the repository's defaults

**No finalizer**, where every other child Application has one. Deleting a Namespace deletes
*everything inside it*, so `resources-finalizer.argocd.argoproj.io` here would turn a mistyped
`kubectl delete app tenant-namespaces` into the loss of the tenant, its database and its volume.
Without it, deleting the Application orphans the namespace and re-applying the file re-adopts it —
recovery stays the cheap path (ADR-0002).

**`prune: false`**, where everything else in this repository prunes. Pruning is what makes Git the
description of the cluster: delete the file, the resource goes. Here, deleting
`shopverse-prod.yaml` would delete the namespace and every object in it, including MongoDB's PVC
and therefore its Persistent Disk — **a one-line change in Git as unrecoverable data loss.**
Removing a tenant means deleting the namespace by hand, once, on purpose. That is the correct
amount of friction for that operation.

### And a check, because the hole was invisible rather than hard

`make gcp-smoke` now reads the namespace's `argocd.argoproj.io/tracking-id` annotation and fails
if it is absent. A namespace existing is not the same as a namespace being managed, and that
distinction is the whole reason this went unnoticed for five modules.

**The on-prem `make smoke` has no equivalent check yet**, which is the same gap one substrate over
— worth adding the next time that cluster is up, along with confirming the adoption actually
happened.
