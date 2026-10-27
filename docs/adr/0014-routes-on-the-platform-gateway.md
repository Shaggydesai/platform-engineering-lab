# ADR-0014: a wildcard listener, and routes that live with their application

**Status:** Accepted
**Date:** 2026-10-27
**Decides:** how an application gets a name on the platform Gateway, and where its HTTPRoute
lives.

## Context

ADR-0013 built one Gateway answering on `gw.platform.local` with a certificate for that exact
name. Argo CD's UI is the first thing that needs to be served through it, and Module 04 already
set `global.domain: argocd.platform.local` and `configs.cm.url` in the Argo CD values, with a
comment saying ingress arrives in Module 05.

A listener's `hostname` **constrains which routes may attach to it**: a route for
`argocd.platform.local` cannot attach to a listener that says `gw.platform.local`. So the first
application was always going to force this decision.

## Decision

### 1. One wildcard listener and one wildcard certificate

`*.platform.local`, on both the HTTPS listener and the Certificate. Adding an application means
adding an HTTPRoute and an `/etc/hosts` line — never touching the Gateway and never reissuing a
certificate.

The alternative was a listener and a certificate per application, which turns every new service
into a change to the shared ingress object. On a platform whose whole premise is that tenants do
not need the platform team, that is the wrong seam.

A public CA would not issue a wildcard for a domain nobody owns. Ours signs it without ceremony,
and this is the one thing a private CA is unambiguously better at than a real one.

What a wildcard does **not** cover is worth stating because the error message does not:
`*.platform.local` matches `argocd.platform.local`, not `platform.local` itself, and not
`a.b.platform.local`. A name outside the wildcard produces a TLS error that reads like a CA
problem rather than a naming one.

### 2. The HTTPRoute lives in the application's namespace

`argocd`, not `platform-ingress`. Two reasons, and the second is the real one.

A `backendRef` that crosses namespaces requires a `ReferenceGrant` in the **target** namespace
permitting it. A route sitting beside its backend needs none. So this placement removes an object
rather than adding one.

More importantly it is where the ownership boundary actually is: the app team owns its route, the
platform team owns the Gateway. Putting every route in the platform's namespace would mean every
new service is a commit against platform-owned config.

### 3. The parentRef crosses namespaces; the backendRef does not

This is the Gateway API distinction that is easiest to conflate, and both halves are in play
here:

| | Object | Lives in | Controls |
|:--|:--|:--|:--|
| `allowedRoutes.namespaces` | the Gateway's listener | platform's namespace | who may **attach** a route |
| `ReferenceGrant` | the backend's namespace | app's namespace | who may **point at** a backend here |

The Gateway's listeners say `from: All`, so a route in `argocd` may attach to a Gateway in
`platform-ingress`. Its backend is local, so no `ReferenceGrant` is needed. A route whose backend
lived in a third namespace would need both, and the failure modes differ: a disallowed attachment
leaves the route `Accepted=False`; a missing grant leaves it accepted with the backend
unresolved, which surfaces as a 500 at request time rather than as a status condition anyone was
watching.

`ReferenceGrant` therefore remains the one of the four CRDs the Ansible role waits on that
nothing in this repository uses. That is correct rather than an oversight, and it is why the role
waits on it anyway: the first cross-namespace backend should fail on a missing grant, not on a
missing CRD.

### 4. `sectionName: https` is not optional

Without it a route attaches to **every** compatible listener. The Gateway also has an HTTP
listener on port 80 for redirect handling later, so an unpinned route would serve the Argo CD
login page unencrypted on the same address, with no error anywhere. Pinning the listener is the
difference between one way in and two.

### 5. The backend is port 80

`argocd-values.yaml` sets `server.insecure: true`, so `argocd-server` serves plain HTTP and the
Gateway terminates TLS. Pointing at 443 would have the Gateway re-encrypt to a certificate
`argocd-server` self-signed and then refuse to verify it.

The hop from the Gateway to the pod is therefore unencrypted, inside the cluster, on the pod
network. That is a deliberate and ordinary trade; it stops being ordinary the moment anything
untrusted shares the pod network, and `server.insecure: true` already carries a comment saying
so.

### 6. `make argocd-ui` stays

The port-forward is not superseded by this. It is the recovery path, and it works precisely
because it depends on none of this — not the Gateway, not the address pool, not the L2
announcement, not cert-manager. Deleting it would mean the only way to reach Argo CD goes through
four components that Argo CD itself manages, which is the position ADR-0002's layering exists to
avoid.

## Consequences

- Every name still needs an `/etc/hosts` line: the certificate covers the whole wildcard, and
  nothing on this network resolves anything. `clusters/onprem/nodes.json` carries
  `gateway_hostnames` and `make hosts` writes them all.
- `make lint` now also checks that the wildcard matches between `nodes.json` and the overlay,
  that every hostname is actually covered by it (exactly one extra label), that
  `gateway_hostname` appears in the list `make hosts` writes, and that every enabled route's
  hostname is a name the workstation will resolve. All five were tested by breaking them.
- Browsers will refuse the certificate until `platform-ca` is imported into the OS trust store.
  That is the honest consequence of a private CA, not a defect, and importing it is a decision
  about a machine rather than about this repository.
