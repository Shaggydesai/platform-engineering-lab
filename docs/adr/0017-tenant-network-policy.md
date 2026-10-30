# ADR-0017: the platform writes the tenant's network policy

**Status:** Accepted
**Date:** 2026-10-30
**Decides:** who writes a tenant's network policy, in which policy language, and how it is proven
to be enforced.

## Context

ADR-0016 ended with an unpaid debt: the `tenants` AppProject blacklists
`networking.k8s.io/NetworkPolicy` inside the tenant's own namespace, so ShopVerse's chart ships
policies it is not allowed to create, and the platform was supposed to supply them instead. It
had not.

Meanwhile the `tenants` project describes itself as ensuring "a tenant cannot reach outside its
own namespaces", which at the network level was simply false — there were no policies at all.
ADR-0007 also chose Cilium partly because "the platform needs NetworkPolicy from Module 06
onward, when ShopVerse arrives as a tenant."

## Decision

### 1. The platform writes them, and the tenant cannot remove them

`gitops/charts/tenant-network-policies`, in the **platform** project, rendering objects into the
tenant's namespace. Same shape as the HTTPRoutes in `platform-ingress`: the object lives beside
what it governs, the decision does not.

`selfHeal: true` matters more here than anywhere else in the repository. A policy someone deletes
to debug something, and then forgets, leaves the database open with nothing reporting it.

### 2. Written from an observed graph, not from the deployment's convenience

The chart's own policy allowed **any pod of the release** to reach MongoDB. Hubble was asked what
actually connects, across a full checkout, and saw exactly five:

```
user-service · product-service · cart-service · order-service · payment-service
   ->  shopverse-mongodb-0:27017
```

`frontend` and `api-gateway` never did, and the chart's env wiring agrees — the gateway proxies
HTTP and holds no database connection. So they are not listed, and a compromised frontend cannot
read the orders collection.

That is the difference between a policy that **documents the architecture** and one that
**permits whatever is already happening**. The second kind passes every test and protects
nothing.

### 3. Plain `networking.k8s.io/v1`, not CiliumNetworkPolicy

Pod-to-pod intent means the same thing on GKE and EKS as it does here, and ADR-0001's premise is
one platform definition across three substrates. Cilium enforces it and Hubble observes it;
nothing in the object is Cilium-specific.

Worth restating because it is the opposite of a firewall's semantics: a pod with **no** policy
selecting it accepts everything. Selecting a pod at all switches it to deny-by-default for that
direction, and the rules are the only exceptions. So one object both denies and permits, and
deleting the file does not "open" the database — it returns it to accepting everything.

### 4. Ingress only. Egress is deferred, deliberately

An egress policy must also permit DNS to `kube-dns`, or every service loses name resolution — and
that failure presents as the application being broken rather than as a policy being wrong. Egress
is its own change with its own test. A compromised pod can currently still call out.

### 5. "Let the front door in" is the one rule that cannot be written portably

This is the finding worth keeping, and it was not obvious before Hubble was asked.

Traffic reaching the frontend arrives as:

```
10.244.1.207:48622 (host) -> shopverse-prod/shopverse-frontend-…:8080
```

`(host)` — Cilium's Envoy runs in the host network namespace, so it presents as
`reserved:host`. **Plain NetworkPolicy has no selector for that.** There is no `fromEntities`, and
an `ipBlock` would have to name each node's `cilium_host` address, which is per-node and changes
when the cluster does.

It is worse than inexpressible. Cilium's `allow-localhost` default auto-allows only the **local**
host, so a naive policy would work while the L2 announcement lease and the frontend happen to sit
on the same node, and break when the lease moved — which ADR-0013 measured happening in about
fifteen seconds whenever a node dies. A rule that is correct until a failover is worse than no
rule, because it will be trusted.

So the edge rule is **not in this chart yet**, and when it arrives it will be substrate-specific:
`reserved:host` here, a Google-owned range on GKE, a VPC ENI on EKS. The per-environment overlay
mechanism is exactly the right place for it, and the `gcp`/`aws` overlays say so.

The general shape: **the portable policy language covers traffic between your own pods and stops
precisely at the boundary where traffic enters.** That boundary is where every substrate differs.

### 6. Proven by denying something

`make netpol-check` runs three probes, and the third is what makes the other two mean anything:

1. the application still works — `/api/products` reaches MongoDB through product-service
2. a pod the policy does **not** list cannot reach the database
3. a pod the policy **does** list **can**

Two pods, same namespace, same image, differing in one label value. Without probe 3, a crashed
MongoDB produces identical output to a working policy — probe 2 would pass against a database
that was simply down, and the check would be another green light that means nothing.

The dropped connection times out rather than failing fast, because a dropped packet produces no
RST. That silence is the policy working.

## Consequences

- A tenant cannot see, edit or delete the policy that governs it, and cannot tell from inside its
  namespace why a connection was refused. `hubble observe --verdict DROPPED` is the platform-side
  answer, and a tenant has no access to it. That asymmetry is deliberate and is a real cost.
- Adding a service that needs the database is now a change to a platform file, not a tenant one.
  That is the correct boundary and it is also friction: the tenant cannot ship such a change alone.
- The namespace is **not** created by this Application (`CreateNamespace=false`). If
  `shopverse-prod` does not exist there is nothing to police, and creating it here would make the
  policy Application the owner of a namespace the tenant lives in.
- Nothing here is verified at the time of writing. The sections above will be wrong somewhere.
