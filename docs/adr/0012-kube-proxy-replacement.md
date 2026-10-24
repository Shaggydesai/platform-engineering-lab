# ADR-0012: replace kube-proxy now, because Gateway API requires it

**Status:** Accepted
**Date:** 2026-10-24
**Decides:** when kube-proxy is removed, and who installs the Gateway API CRDs.
**Amends:** ADR-0007 (which deferred this to a module that does not exist), ADR-0009 Decision 1
(whose wording was imprecise about what Ansible owns in-cluster)

## Context

Module 05 needs ingress, and ADR-0007 chose Cilium partly so that ingress would be Gateway API
from the CNI rather than a separate controller. Cilium's documentation then says plainly:

> `kubeProxyReplacement=true` is required.

That contradicts the second half of ADR-0007, which kept kube-proxy on purpose:

> You cannot understand a replacement for something you never saw working. [...] Starting at the
> end state teaches neither — it just produces a cluster that works for reasons you have not seen.

And it exposes a mistake in that ADR: it promised the removal "in Module 04 as a deliberate,
reversible exercise". The roadmap's Module 04 is Argo CD. I wrote a module number that did not
correspond to anything, and nothing caught it until a requirement forced the issue — which is a
small argument for ADRs referencing *roadmap items* rather than numbers, and a larger one for
re-reading your own decisions when they come due.

## Decision 1 — kube-proxy is replaced now, and the before/after still happens

The pedagogical goal of ADR-0007 is met, not abandoned. kube-proxy has been running since
Module 02; Services, DNS and the smoke test have all been exercised through it. What was never
going to happen is a leisurely Module 04 exercise, because the forcing function arrived first.

So the removal is done **deliberately and with the comparison recorded**, which is what ADR-0007
actually wanted:

```bash
# BEFORE, on a node. These are kube-proxy's Service rules.
sudo iptables-save | grep -c KUBE-SVC
sudo iptables-save | grep -A3 'KUBE-SVC.*kubernetes:https'

# AFTER: the same lookups, in eBPF maps instead
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
```

**This is a good moment for it, and that is not a coincidence.** The cluster has a canary
ConfigMap, metrics-server and cert-manager on it. Nothing serves traffic, no tenant exists, and
Module 03 rebuilds the whole thing in four minutes if this goes wrong. Doing it in Module 06,
with ShopVerse running, would be the same change with a worse blast radius.

**Two pieces of earlier foresight make this cheap**, and both were recorded at the time:

- `k8sServiceHost`/`k8sServicePort` are already set in the Cilium values, so cilium-agent reaches
  the API server by name rather than through the `kubernetes.default` ClusterIP. That ClusterIP
  is programmed *by kube-proxy* — without those settings, removing kube-proxy would leave Cilium
  unable to start, and nothing able to fix it. The comment in `cilium-values.yaml` predicted
  exactly this.
- Module 03 means the cluster is disposable. The decision to make rebuilding cheap is what makes
  a risky change cheap.

**kubeadm must also stop installing it.** `proxy.disabled: true` goes into the kubeadm
`ClusterConfiguration`, otherwise the next rebuild reintroduces kube-proxy and two components
program Service rules at once — which does not fail cleanly. The `KubeProxyConfiguration`
document is removed from the config at the same time, because configuring a component you have
disabled is a lie in a file somebody will later believe.

## Decision 2 — Ansible installs the Gateway API CRDs, and ADR-0009's wording is corrected

Cilium requires the Gateway API CRDs to exist *before* `gatewayAPI.enabled=true` does anything.
They are a prerequisite of the CNI, so they belong with the CNI: **Layer 1, installed by
Ansible.**

That reveals ADR-0009 Decision 1 as imprecisely worded. It said:

> Ansible applies `gitops/bootstrap/` and nothing else in the cluster.

Which was already false when written — Ansible installs the Cilium Helm release, and that
creates plenty of in-cluster objects. What the rule *meant*, and now says:

> **Ansible owns Layer 1 in-cluster components** — the CNI, its prerequisites, and nothing that
> depends on Argo CD existing. **Layer 2 is Argo CD itself plus exactly the three objects in
> `gitops/bootstrap/`.** Argo CD owns everything the root Application reaches. Nothing is added
> to `gitops/bootstrap/` without amending ADR-0009.

The closed-set rule that matters is unchanged; it was always about the *seam*, not about every
object Ansible has ever created. `make gitops-drift` already encodes the correct version of
this, since it exempts `kube-system` as "Layer 1" rather than claiming Ansible touches nothing.

**The CRDs are pinned by content, not just by version.** The Ansible role downloads
`standard-install.yaml` for the pinned Gateway API version, verifies its SHA-256 against
`nodes.json`, and refuses to apply it if they differ. A version tag is a mutable pointer; a
digest is not. This is the same discipline as `Chart.lock` for wrapper charts, applied to the one
thing in this repository that arrives as a raw URL.

## Consequences

**Good.** Service load balancing moves into eBPF maps: no long iptables chains, no linear rule
traversal, and `cilium-dbg service list` as a readable answer to "where does this ClusterIP go?".
Gateway API becomes available from the component that already exists, with no second ingress
controller — which was one of ADR-0007's two reasons for choosing Cilium, now collected.

**Costly.** `iptables-save | grep KUBE` stops being a debugging tool, and that is a real loss on
a cluster where it has been the first thing to reach for. The replacement is `cilium-dbg` and
`hubble`, which are better but unfamiliar — exactly the trade ADR-0007 flagged as Cilium's main
cost, now paid.

**Risk.** If the eBPF datapath does not program a Service correctly, there is no iptables
fallback to limp along on: it is the only implementation now. Mitigated by `make smoke`, which
tests DNS, ClusterIP routing and cross-node pod traffic — and by `make onprem-up` rebuilding the
cluster in four minutes. The rollback is `kubeProxyReplacement: false` plus a rebuild, and it is
written down in `docs/runbooks/05-gateway.md` rather than left as an exercise.
