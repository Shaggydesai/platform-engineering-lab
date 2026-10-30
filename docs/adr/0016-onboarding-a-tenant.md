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
and it means the platform must supply them instead, which it does not yet.

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
