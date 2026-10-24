# ADR-0011: a self-signed root on-prem, public certificates in the cloud

**Status:** Accepted
**Date:** 2026-10-24
**Decides:** who signs certificates on each substrate, and what "trusted" means in each case.

## Context

Two parking-lot entries are both the same problem: there is no certificate authority in this
cluster, so every component that needs TLS either self-signs or skips verification.

- metrics-server scrapes kubelets whose serving certificates are self-signed by kubeadm, so it
  runs with `--kubelet-insecure-tls`.
- The aggregation layer does not verify metrics-server's own certificate, because the chart sets
  `insecureSkipTLSVerify: true` on the APIService for the same reason.

Module 05 also needs a Gateway serving HTTPS, and Module 06 puts a tenant workload behind it.
Both need a certificate from somewhere, and "somewhere" has to be decided once rather than per
component — otherwise each component self-signs and the cluster accumulates a dozen unrelated
trust roots, which is indistinguishable from no security at all while looking like some.

The substrates genuinely differ here, which is the interesting part.

## Decision

**On-prem: a self-signed root CA, created by cert-manager, in three steps.**

```text
ClusterIssuer  selfsigned-bootstrap    signs with nothing. Used exactly once.
       │
       ▼
Certificate    platform-ca             isCA: true, ECDSA P-256, 10 years
       │                               private key -> Secret platform-ca-tls
       ▼
ClusterIssuer  platform-ca             what every other component references
```

The three steps exist because cert-manager can only create a certificate by asking an Issuer,
and a root — which by definition nothing else signs — needs an Issuer that signs with nothing.
The indirection is not ceremony: **every other component references `platform-ca` and nothing
else**, so replacing the self-signed root later (with an intermediate signed by a real CA, say)
changes one file and nothing in any other component.

**Cloud: publicly trusted certificates via ACME, DNS-01.** GKE in Module 08 and EKS in Module 09
both get a public DNS name, so a public CA can validate it. The issuer is an `ACME`
ClusterIssuer solving DNS-01 against Cloud DNS or Route 53.

This is expressed as one boolean, `platformPKI.enabled`, in
`gitops/environments/<env>/cert-manager.yaml`. Same component, same chart, different trust
model — the clearest demonstration in this repository of what `gitops/environments/` is for.

## Why not the obvious alternatives

**Why not use the Kubernetes cluster CA as the root?** It already exists, kubeadm made it, and
every node already trusts it. Tempting, and wrong for two reasons. It would mean handing
cert-manager the key that signs API server and kubelet certificates — so a flaw in anything that
can request a certificate becomes a flaw in the control plane's identity. And the cluster CA
rotates on a kubeadm schedule tied to the cluster's own lifecycle, which has nothing to do with
how long a workload's certificate should live. Two authorities with two lifetimes and two blast
radii is correct here.

**Why not a public CA on-prem too?** There is no public DNS name for `192.168.100.0/24` and no
way for any public CA to validate one. The alternatives are a DNS-01 challenge against a real
domain whose records point at a cluster nobody can reach, or lying. A self-signed root that we
distribute ourselves is the only option that is honest about what is being trusted.

**Why not skip TLS on-prem entirely?** Because Module 06 puts a tenant workload behind a Gateway
and Module 12 ships a release through CI, and a platform where TLS "would work in production" has
never had its TLS tested. The point of three substrates is that the platform definition is the
same on all three; TLS being absent on one of them would make that false.

## What this does not solve, and what it costs

**Nothing outside the cluster trusts this root.** A browser on the Windows host will refuse the
Gateway's certificate until the root is installed in the Windows trust store, and `curl` will
need `--cacert`. That is not a flaw in the design; it is what a private CA means. Exporting the
root for the host is a Module 05 step, and exporting it is safe — the certificate is public by
nature, only the key in `platform-ca-tls` is secret.

**Pods do not automatically trust it either.** A pod's CA bundle comes from its image, and this
root is not in any of them. Distributing it into pods needs trust-manager, which is deliberately
not installed yet: nothing in Module 05 makes a TLS connection *from* a pod *to* a platform
service by name. The first component that does is the moment to add it, and adding it before
then would be a component with no consumer.

**The parking-lot entries are not closed by this ADR.** cert-manager existing makes them
fixable, not fixed:

- metrics-server's kubelet scrape needs `serverTLSBootstrap` on the kubelets plus a CSR-signing
  controller, which cert-manager can now be. That is a Module 05 follow-up, and it touches the
  kubeadm KubeletConfiguration — so it is a cluster rebuild, which is cheap (Module 03) but not
  free.
- The APIService's `insecureSkipTLSVerify` needs metrics-server to present a certificate the
  API server trusts, which cainjector can now arrange.

Both get fixed **together**, because fixing one alone leaves an unverified hop either side of a
verified one, which buys nothing and looks like it bought something.

## Consequences

**Good.** One issuer name, `platform-ca`, is the only thing any component references. The trust
model differs per substrate by one boolean rather than by a different component. Replacing the
root is a one-file change.

**Costly.** A root nothing outside the cluster trusts, so every external client needs it
installed or passed explicitly — and that friction will be felt every time the Gateway is opened
in a browser. Ten-year root validity means this decision is not revisited by expiry; it has to
be revisited deliberately or not at all.

**Risk.** The private key for the platform's root CA lives in one Secret in one etcd, on a
laptop, unencrypted at rest. For a lab that is acceptable and should be stated rather than
implied. Module 07 decides how secrets are handled and Module 11 how etcd is backed up; until
both exist, the honest summary is that this CA is exactly as secure as the laptop.
