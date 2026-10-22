# ADR-0007: Cilium is the CNI, and kube-proxy stays until we remove it deliberately

**Status:** Accepted
**Date:** 2026-10-22
**Decides:** which CNI plugin provides pod networking on all three substrates, and when
kube-proxy is replaced.

## Context

A Kubernetes cluster with no CNI is a cluster where every node is `NotReady` and no pod gets an
address. kubeadm deliberately does not install one, because the choice shapes almost everything
that comes later: whether NetworkPolicy exists at all, how Services are implemented, what the
ingress story looks like, and what you can observe when traffic does not arrive.

It is also the hardest thing in this project to change later. Changing CNI on a running cluster
means every pod's address changes and every policy is re-expressed. In practice you rebuild the
cluster — which is cheap here (Module 01 rebuilds the nodes in 30 seconds) but is not cheap on
GKE or EKS, and is certainly not cheap once the platform has tenants on it.

So it gets decided now, with reasons, before `kubeadm init` runs.

The constraints that matter:

- Nodes are small: the control plane has 2 vCPU and 4 GB (ADR-0004).
- The platform needs **NetworkPolicy** from Module 06 onward, when ShopVerse arrives as a tenant
  and the point is to prove isolation rather than assume it.
- Module 05 is **Gateway API**, not Ingress.
- The same platform definition has to work on GKE and EKS (ADR-0001), so skills that only exist
  on-prem are worth less than skills that transfer.
- Guest kernel is Ubuntu 24.04's 6.8, which is modern enough for eBPF regardless of the fact that
  the host underneath is WSL2. The guest runs its own kernel; nesting does not change this.

## Options considered

| | Flannel | Calico | Cilium |
|:--|:--|:--|:--|
| Dataplane | VXLAN | iptables or eBPF | eBPF |
| NetworkPolicy | **none** | yes, plus its own CRDs | yes, plus L7 policy |
| Gateway API | no | no (needs a separate controller) | **built in** |
| Can replace kube-proxy | no | partly | yes |
| Observability | none of its own | limited | Hubble — flow logs, service map |
| Footprint per node | ~50 MB | ~150 MB | ~250 MB |
| Difficulty when it breaks | low | moderate | **high** |
| What the managed clouds use | — | EKS add-on option | **GKE Dataplane V2 _is_ Cilium** |

**Flannel is out** on NetworkPolicy alone. A platform whose selling point is multi-tenancy cannot
have a network where every pod can reach every other pod forever. Adding a policy engine on top
later means running two network components, which is worse than picking one that does both.

**Calico is the safe answer** and a defensible one. It is the most widely documented CNI, the one
most interview questions assume, and it fails in ways that are easy to find help for. If this
project stalls again on networking, Calico is the thing I would switch to.

**Cilium wins on transfer and on consolidation.** Two arguments decide it:

1. **GKE's Dataplane V2 is Cilium.** Module 08 builds a GKE cluster. Learning Cilium on-prem is
   therefore learning the thing that is already running in the cloud half of this lab, rather
   than learning a second CNI and hoping the concepts map. That is exactly the "one platform,
   three substrates" premise of ADR-0001 paying off.
2. **It removes a component from Module 05.** Cilium implements Gateway API itself. With Calico
   we would also install Envoy Gateway or NGINX Gateway Fabric — one more chart, one more
   failure mode, one more thing to reason about when a request does not arrive.

The honest cost: when Cilium misbehaves, the answer is in eBPF maps and `cilium-dbg`, not in
`iptables -L`. That is a real step up in debugging difficulty, and it is the reason for the
second half of this decision.

## Decision

**Cilium, installed with Helm, in its default mode — with kube-proxy still present.**

kubeadm installs kube-proxy as normal. Cilium runs alongside it and handles pod networking and
NetworkPolicy. `kubeProxyReplacement` stays off for now.

**kube-proxy is removed in Module 04 as a deliberate, reversible exercise**, not as part of the
bootstrap.

### Why not go straight to kube-proxy replacement

It is tempting, because the end state is cleaner and avoids a migration. Two reasons not to:

**You cannot understand a replacement for something you never saw working.** Module 02 exists so
that `iptables-save | grep KUBE-SVC` means something. Watching kube-proxy program service rules,
then removing it and watching Cilium do the same job in eBPF maps, teaches both. Starting at the
end state teaches neither — it just produces a cluster that works for reasons you have not seen.

**It keeps the first bootstrap debuggable.** If a Service does not answer in Module 02, with
kube-proxy present the question is "is it DNS, Service, or CNI" — three suspects with familiar
tools. With kube-proxy replaced on day one it is also "or is it the eBPF datapath", and the tools
for that suspect are ones we have not learned yet. Rule 2 of the roadmap exists because of
exactly this kind of compounding.

The migration cost we are accepting is small and bounded: set `kubeProxyReplacement=true`, delete
the kube-proxy DaemonSet, flush the leftover iptables chains on each node. It is an afternoon,
documented in Module 04, and it is reversible.

### Settings fixed here

| Setting | Value | Why |
|:--|:--|:--|
| Pod CIDR | `10.244.0.0/16` | must not overlap the node network `192.168.100.0/24`, and the /16 is what every tutorial assumes, which helps when reading them |
| Service CIDR | `10.96.0.0/12` | kubeadm's default; no reason to differ |
| IPAM | `cluster-pool` | Cilium hands out per-node ranges from the pod CIDR itself, rather than relying on the `Node.spec.podCIDR` that kube-controller-manager assigns |
| Tunnel | VXLAN | native routing needs the underlay to route pod CIDRs; libvirt's NAT network will not, and GKE/EKS differ anyway. One mode across substrates is worth more than marginal throughput |
| Hubble | enabled, no UI yet | flow logs are the single best teaching tool for "why did this packet not arrive". The UI arrives via Argo CD in Module 10, not by hand |
| kube-proxy replacement | off | see above; revisited in Module 04 |

The pod and service CIDRs are recorded in `clusters/onprem/nodes.json` so that Terraform,
Ansible and the kubeadm config cannot disagree about them.

## Who owns it

The CNI is **Layer 1** in ADR-0002 — machine configuration, owned by Ansible. It cannot be
Layer 3, because Argo CD needs a working pod network before it can run at all; a CNI managed by
Argo CD would be a component that must exist before the thing that installs it.

In Module 02 it is installed **by hand, once**, because Module 02 is the one module where manual
work is the point. Module 03 moves that exact installation into an Ansible role, and the gate for
Module 03 is that a cluster built entirely by Ansible is indistinguishable from this one.

## Consequences

**Good.** One component provides pod networking, NetworkPolicy, L7 policy, Gateway API and flow
observability. The on-prem dataplane matches GKE's. Module 05 installs no separate ingress
controller.

**Costly.** ~250 MB per node, and a debugging surface that needs `cilium-dbg` and `hubble`
rather than `iptables`. The control plane at 4 GB has less headroom than it would with Flannel.

**More components than expected.** The install produced three things per node, not one:
`cilium` (the agent), `cilium-envoy` (a separate DaemonSet) and `cilium-operator`. Envoy is no
longer embedded in the agent; it runs alongside it and is what serves L7 policy and Gateway API.
That is not waste — Module 05 needs it, and it is the component that replaces the separate
ingress controller Calico would have required — but it is roughly another 100 MB per node that
the comparison table above did not account for. Measured, the real figure is closer to 350 MB.

**Hubble Relay is installed without TLS**, which the chart warns about. Recorded in
`docs/parking-lot.md` rather than fixed, because issuing certificates by hand would create
precisely the hand-made component ADR-0002 Rule 3 forbids. It is revisited in Module 10.

**Risk.** If Cilium becomes the thing that stalls this project, the escape hatch is Calico: pod
CIDR and service CIDR are unchanged, so it is a cluster rebuild rather than a redesign — about
ten minutes, given Module 01. That escape hatch is the reason this decision is safe to make
without agonising over it.
