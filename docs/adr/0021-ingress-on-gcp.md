# ADR-0021: ingress on GKE, and an address you do not get to choose

**Status:** Accepted
**Date:** 2026-11-02
**Decides:** how the storefront and the Argo CD UI are reached on GKE; which GatewayClass; where
the Gateway's address comes from; how TLS is issued now that ACME is cancelled; and the teardown
ordering that keeps ADR-0003 true. Completes Module 08's Layer 3.

## Context

ADR-0013 and ADR-0014 built ingress on-prem: a Cilium LB-IPAM pool, an L2 announcement policy, a
platform-owned Gateway with a wildcard listener, a cert-manager Certificate from `platform-ca`,
and one HTTPRoute per application in the application's own namespace.

`gitops/environments/gcp/platform-ingress.yaml` had every one of those switched off, with this
reasoning:

> *"Ingress, gcp — everything off. Not 'not yet configured': off on purpose [...] On GKE a
> `type=LoadBalancer` Service is fulfilled by a Google network load balancer, which the cloud
> provisions and announces itself. An address pool here would claim addresses the provider also
> believes it owns, and L2 announcements would ARP for them on a network that does not carry L2
> between nodes in the first place."*

**Every sentence of that is still true, and none of it was an argument for having no ingress.** It
was an argument against the on-prem *mechanism* — the pool and the announcement. The Gateway,
which is the actual contract, was never examined. Writing it off along with the mechanism is the
same conflation ADR-0020 found with metrics-server, in the other direction: there, a component
that *is* Google's job was nearly deployed anyway; here, a component that is ours was nearly
skipped because its implementation is Google's.

Module 08's bar says the storefront is reachable through a cloud load balancer. It is also the
last thing in the module.

## Decision

### 1. GKE Gateway API, not Ingress and not a bare LoadBalancer Service

The same `Gateway`, the same two listeners, the same wildcard hostname, the same
`allowedRoutes.namespaces.from: All`, and the same HTTPRoutes — including the tenant's, which is
written by the application's own chart and not by this platform.

**What differs is two values: the GatewayClass, and where the address comes from.** That is the
strongest single result ADR-0001 has produced, and it is why `gitops/charts/platform-ingress`
stays one chart rather than becoming two.

**Why not an Ingress object.** It would work — GKE has a built-in Ingress controller — and that is
precisely the hazard ADR-0016's correction already recorded for the tenant: `ingress.enabled:
true` on this substrate reports Synced and Healthy, serves the storefront, and bills monthly. It
is also a weaker contract: no wildcard listener a tenant can attach to without the platform
editing anything, which is ADR-0014's whole design.

**Why not a `type=LoadBalancer` Service.** An L4 network load balancer, one address per service,
no host-based routing, no TLS termination, and nothing for an HTTPRoute to attach to. It is
cheaper and it is not the same contract.

### 2. `gke-l7-global-external-managed`, and the rejected alternative is the interesting one

| class | verdict |
|:--|:--|
| `gke-l7-global-external-managed` | **chosen.** A global anycast frontend; no extra VPC resource. |
| `gke-l7-regional-external-managed` | rejected — **not** for performance. |

A regional external Application Load Balancer requires a **proxy-only subnet**: a second subnet in
the VPC with `purpose = REGIONAL_MANAGED_PROXY`. Without it the Gateway is **accepted and never
programs**. The subnet costs nothing; it is one more resource that must exist, in a field whose
value is easy to get wrong, and its absence is a classic "the Gateway never came up" cause that
points nowhere useful.

Fewer moving parts wins on a substrate rebuilt every session. The trade is honest and small: a
global and a regional forwarding rule are billed in the same band, and nothing here measures
latency.

**Gateway API is not installed on GKE unless asked.** `gateway_api_config { channel =
"CHANNEL_STANDARD" }` on the cluster resource installs the CRDs and the controller; without it a
`Gateway` cannot be applied at all and the error names an unknown kind, which reads like a chart
problem. **This is the same seam as ADR-0012 Decision 2, one layer further away:** on-prem,
Cilium's `gatewayAPI.enabled` does nothing unless the CRDs exist and that capability is a Helm
value applied by Ansible — Layer 1. Here the CRDs are Google's to install and the switch is in
Terraform — Layer 0. The boundary keeps moving outward on this substrate, which is what "managed"
keeps meaning.

### 3. The address is an allocation, not a choice — and that is a real difference

This is the finding worth keeping from this ADR.

On-prem an address is a **configuration choice**. ADR-0013 picked `192.168.100.200` out of a range
this project owns, wrote it in `nodes.json`, pinned it in the overlay, and `make hosts` writes the
workstation's hosts file from the same file. It does not move between rebuilds, and pinning it
costs nothing.

On GKE it is an **allocation**. The load balancer is given a public address when it is created, a
different one each session, and reports it in `status.addresses`. **Pinning it means reserving a
static external address — which GCP bills while it is not attached to anything**, i.e. in exactly
the state this lab spends most of its life in. ADR-0003 forbids a standing charge however small.

So the address moves and the names stay:

```
make gcp-address     # the current address, and the hosts lines to match
```

The chart used to *hard-fail* without `gateway.address`, with a comment that reads well and is
substrate-specific: *"a Gateway whose address moves is worse than one with no name pointed at
it."* True of LB-IPAM, where you own the range; not true of a cloud, where the alternative to a
moving address is a bill. So `gateway.addressFrom` is now an explicit value — `pinned` or
`provider` — and the template **refuses both incoherent combinations**: `pinned` with no address,
and `provider` with one. The second matters more than it looks: a cloud silently ignores an
address it did not allocate, so without the guard the overlay could claim a pinned address and
nothing would contradict it.

### 4. TLS from `platform-ca`, which reverses an earlier decision

`gitops/environments/gcp/cert-manager.yaml` said `platformPKI` stays off because this substrate
would use an ACME ClusterIssuer with DNS-01 against Cloud DNS. **It cannot**: DNS-01 needs a
public DNS zone (a standing charge) and a domain this project does not own. ADR-0018's amendment
recorded that as cancelled rather than deferred.

That left two options: a self-signed root, or no TLS at all.

**Self-signed wins on the contract, not the cryptography.** With it, TLS terminates at the Gateway
on both substrates, the `Certificate` object is identical, the wildcard is identical, and the
renewal path is identical — 90 days with rotation at 75, on a CA good until 2036. Without it, "the
platform terminates TLS at the edge" would be true on the laptop and false in the cloud, which is
exactly the quiet divergence ADR-0001 exists to catch.

**What it costs, stated rather than glossed:** a browser pointed at this load balancer gets a
certificate warning, from a public address. That is the honest consequence of a private CA and not
a misconfiguration. `make gcp-ca` exports the root so `curl` can verify it — and writes it to
`.cache/gcp-platform-ca.crt`, **not** the on-prem `platform-ca.crt`, because the two clusters each
generated their own unrelated root from the same chart. Using the wrong file produces a
verification error that reads like a broken certificate.

A publicly trusted certificate here needs a domain name. Buying one is a decision about money, not
about Kubernetes, and it is not this ADR's to make.

### 5. The teardown order, which is the only thing here with money on it

The Gateway is reconciled into a Google load balancer: a forwarding rule, a target proxy, a URL
map, a backend service, a health check and a network endpoint group per backend.

**Terraform created none of them and has no record of any of them.** They are made by the GKE
controller, in response to a Kubernetes object, in a cloud project. So destroying the cluster
first removes *the controller that would clean them up* — and GKE's cluster-delete cleanup of load
balancers is documented as best-effort rather than guaranteed. The billed object is the forwarding
rule, and an orphaned one is billed hourly, forever, in a project `terraform destroy` reported
success on.

`make gcp-down` therefore:

1. deletes the `platform-ingress` Application, whose finalizer **must** be present so the delete
   cascades to the Gateway — the opposite of the `tenant-namespaces` decision next door, where a
   finalizer would destroy a namespace and everything in it;
2. polls `gcloud compute forwarding-rules list` until it is empty, up to five minutes;
3. destroys the cluster either way.

**Step 3 happens even if step 2 times out, deliberately.** Refusing to destroy a billable cluster
because a cleanup step could not run would invert the entire point. If the rules are still there,
it says so in red and `make cost-check` lists them afterwards with the removal command — which is
why that script has listed forwarding rules since Module 08 opened.

## Consequences

**Module 08's bar is now met in writing:** the same platform and the same tenant run on GKE from
the same Git repository, and the storefront is reachable through a cloud load balancer.

**`make gcp-smoke` gained an ingress section**, and it checks `Programmed`, not `Accepted`. Those
are different claims — the first means a controller saw the object, the second means a load
balancer exists — and a Gateway can sit `Accepted=True, Programmed=False` indefinitely serving
nothing. That is the Gateway API form of the failure ADR-0016 named for the Ingress object.

**A session now costs slightly more**, and the number should be said: a forwarding rule is roughly
$0.025/hour, so ~₹2/hour on top of the ~₹3/hour for two spot nodes, two external IPs and 64 GB of
pd-standard. An hour-long session is ~₹5 against ₹28,257 of trial credit. **It is also the first
thing in this project whose cost depends on remembering an order of operations** rather than on
remembering to run one command.

**What is NOT verified, and this time the list is short but includes the render itself.** None of
this has run. Specifically:

- **The chart has not been rendered.** `helm` cannot be installed in the environment this was
  written in — `get.helm.sh` is not reachable and npm's `helm-binary` package is a 1.7 KB
  downloader for it — so the new `addressFrom` branching and guards are unexercised. `make lint`
  renders every chart against every environment that deploys it, and now includes
  `platform-ingress (gcp)`, so **the first `make lint` on the laptop is what proves the template**.
  That is a real gap, stated rather than hidden: three of the last session's bugs were in checks
  that had never been run.
- That `gateway_api_config` is an in-place update rather than a replacement. It does not much
  matter — the cluster is destroyed every session — but a plan saying `forces replacement` is
  worth reading rather than approving.
- That `gke-l7-global-external-managed` accepts a `certificateRefs` Secret from cert-manager. It
  is documented to; it has not been seen to.
- That the HTTPRoute to `shopverse-frontend:8080` works through a Google ALB, which inserts a
  health check the on-prem path does not have. **A failing health check is the most likely single
  cause of a Programmed Gateway that returns 502**, and the backend is nginx serving `/`.
- That `make shopverse-check` passes against it. It still has no GCP counterpart: it wants the CA
  and the hostnames, which now both exist here, so porting it is the obvious next piece of work
  and is no longer blocked on a decision.
