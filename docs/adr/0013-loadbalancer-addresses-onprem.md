# ADR-0013: LoadBalancer addresses on-prem, via Cilium LB-IPAM and L2 announcements

**Status:** Accepted
**Date:** 2026-10-27
**Decides:** how a `type: LoadBalancer` Service gets an address that answers on this network,
which addresses it may use, and who owns each half of the mechanism.

## Context

Module 05 needs a Gateway. Cilium's Gateway controller reconciles a `Gateway` into a Service of
type `LoadBalancer`, and on this cluster nothing fulfils that type: libvirt provides a NAT
network and a bridge, not a load balancer. Left alone, the Service sits `<pending>` forever,
the Gateway never reports `Programmed`, and ingress does not exist.

This is the first thing in the project that a cloud provider would simply hand over, and that
asymmetry is the point of the three-substrate comparison in ADR-0001: it is worth knowing
exactly what "a load balancer" means when nobody is selling you one.

## Options

**NodePort, and no load balancer at all.** Set the Gateway's Service to NodePort and reach it on
a high port on any node. Works immediately, costs nothing, needs no new concepts. It also means
every URL in the lab carries a port number, TLS certificates are issued for a name that has to
be reached on `:30xxx`, and the thing that will be different in GKE and EKS — the address — is
the thing that never gets exercised.

**MetalLB.** The usual answer, and it works. But it is a second network component next to a CNI
that already does the job, with its own speaker DaemonSet, its own address pool CRD, and its own
failure modes to learn. Running two things that both want to answer ARP for service addresses is
a way to spend an evening.

**Cilium LB-IPAM with L2 announcements.** The CNI allocates addresses from a pool and answers
ARP for them from one elected node. No new component; two custom resources. Beta.

**Cilium with BGP.** What a real on-prem platform does, and what removes the single-node ARP
bottleneck. It needs something upstream to peer with. There is no router here to peer with, and
inventing one (a FRR container) adds more machinery than the lesson is worth at this stage.

## Decision

**Cilium LB-IPAM with L2 announcements**, addresses `192.168.100.200`–`192.168.100.239`, and the
Gateway pinned to `192.168.100.200`.

### 1. Those addresses are genuinely free

`terraform/onprem/main.tf` declares the platform network with a bridge address and **no DHCP
range at all** — node addresses are assigned by cloud-init inside each guest, not leased. So the
only occupied addresses on `192.168.100.0/24` are `.1` (the libvirt bridge) and `.10`/`.11`/`.12`
(the nodes). Claiming `.200`–`.239` collides with nothing, and nothing will later be handed one
of them by a DHCP server that does not exist.

This matters more than it sounds. An address pool is a **claim on somebody's network**, asserted
by ARP to every machine on it. Getting it wrong on a corporate LAN means answering for an
address that belongs to a printer.

### 2. A range, not a CIDR

`blocks: [{start, stop}]` rather than `blocks: [{cidr}]`. A CIDR immediately raises the question
of whether its network and broadcast addresses are allocatable — which Cilium answers with
`allowFirstLastIPs`, defaulting to allocating them. A range has no such question. (`start` and
`stop` are **one** block and must be a single list item; written as two they become two
half-specified blocks.)

### 3. The Gateway's address is pinned, not allocated

`/etc/hosts` on the workstation points `gw.platform.local` at it, and a name whose address moves
is worse than no name. Pinned with `Gateway.spec.addresses[type=IPAddress]`, which is LB-IPAM
aware and is the supported mechanism. The older `io.cilium/lb-ipam-ips` annotation under
`spec.infrastructure.annotations` does the same job and in fact takes **precedence** where both
are set — Cilium's own documentation shows `spec.addresses` being ignored in that case — but it
is documented as heading for deprecation, so only one of the two appears in the chart.

### 4. Allocation and announcement are separate objects, and only one of them is visible

This is the mental model worth keeping:

| | Object | Scope | What it does |
|:--|:--|:--|:--|
| Allocation | `CiliumLoadBalancerIPPool` | cluster | decides the Service gets `192.168.100.200` |
| Announcement | `CiliumL2AnnouncementPolicy` | cluster | makes some node answer ARP for it |

With only the pool, a Service gets an `EXTERNAL-IP` and **looks finished** while nothing on the
network has ever heard of the address. `kubectl get svc` cannot tell the two apart. Every
verification of this feature has to curl the address from off-cluster, because that is the only
check that distinguishes them.

Note also that the two CRDs are on **different API versions** — the pool is `cilium.io/v2`, the
policy is still `cilium.io/v2alpha1`. They arrived with the same feature; only one graduated.
Assuming they moved together produces a manifest the API server rejects as an unknown type.

### 5. The Layer 1 / Layer 3 seam

- **Layer 1, Ansible, in the Cilium values:** `l2announcements.enabled`, `gatewayAPI.enabled`,
  `kubeProxyReplacement` (which L2 announcements hard-requires), and `k8sClientRateLimit`. These
  are Helm values that change how the CNI behaves.
- **Layer 3, Argo CD, in `gitops/charts/platform-ingress`:** the pool, the policy, the Gateway,
  and its Certificate. These are ordinary custom resources.

The dividing line is ADR-0002's: a Helm value that changes the CNI's behaviour cannot be owned
by the thing that needs the CNI to be working. The **capability** is Layer 1; the **allocation**
is Layer 3.

### 6. Announce from workers only

`nodeSelector` excludes the control plane. Not a correctness requirement — any node on the
network can answer — but `k8s-cp01` has 4 GB and the control plane on it, and being the ARP
responder means carrying the ingress traffic too. It also leaves somewhere to fail over **to**:
with two eligible nodes, killing the announcer proves the lease moves, which a single eligible
node cannot demonstrate.

### 7. The client rate limit is raised, and the reason is not obvious

From 5 qps / 10 burst to 30 / 60. Each announced service takes a `Lease` which the announcer
renews on a timer, so the agents' API traffic now scales with the number of LoadBalancer
Services. Cilium's formula is `qps = services × (1 / leaseRenewDeadline)`; at the default 5s
renew deadline, 30 qps covers 150 services.

The failure this prevents is not an error message. Client-side rate limiting makes the agent
**slow**: renewals arrive late, leases expire, and the announcement flaps between nodes. It
presents as an intermittent network fault.

Lease timings are left at their defaults (15s / 5s / 2s). Shortening them buys faster failover
and costs API requests forever.

## Risks, and what is actually being accepted

**L2 announcements are beta.** Accepted on a lab whose stated purpose is understanding
mechanisms. Noted so that nothing here is copied into something that matters without rechecking
its status.

**One node answers at a time.** Not a load balancer in the load-distributing sense — it is a
failover VIP. All ingress traffic for all LoadBalancer addresses enters through whichever worker
holds the lease. BGP is the answer to that, and it is deliberately not today's problem.

**There is an open upstream issue for exactly this combination.**
[cilium/cilium#43819](https://github.com/cilium/cilium/issues/43819): a Cilium Gateway's address
with L2 announcements reachable from inside the cluster and timing out from outside, with the
Gateway's load-balancer entry showing no backends and marked `l7-load-balancer`, while a plain
LoadBalancer Service on the same nodes worked. Reported against 1.18.x, no root cause identified,
open. We are on 1.20.3 and may be unaffected.

**This is mitigated by how it is verified, not by hoping.** `make smoke` step 7 probes a plain
`type: LoadBalancer` Service — real backends, ordinary datapath, no L7 proxy — from the
workstation. The Gateway is checked separately. If step 7 passes and the Gateway does not, the
fault is isolated to the L7 path rather than to L2 announcements, and that distinction is worth
an hour of not guessing.

**Rollback** is `gateway.enabled: false` plus a NodePort Gateway, which is a values change in
`gitops/environments/onprem/platform-ingress.yaml` and no rebuild. The pool and the policy can
stay: they are useful on their own.

## Consequences

- `make hosts` writes `gw.platform.local` into `/etc/hosts`. **Resolving is not reaching** — the
  name is there whether or not any node is announcing, so the script says which of the two it
  tested.
- The addresses now live in two files: `clusters/onprem/nodes.json` (where `hosts-sync` reads
  them) and `gitops/environments/onprem/platform-ingress.yaml` (where Argo CD does). Argo CD
  renders a chart from Git and cannot reach into `nodes.json`, so the honest options were
  duplication with a check or a generated overlay. `make lint` checks that they agree, that the
  pinned Gateway address is inside the pool, and that no node address is. All three failure modes
  were tested by breaking them deliberately.
- **Reachability from Windows is untested.** The address is announced on the libvirt bridge
  inside WSL, so it works from WSL. Whether Windows can reach it depends on WSL's networking
  mode — NAT mode almost certainly cannot without a static route; mirrored mode may. Claiming
  "reachable from the Windows host" before testing it would be a guess.
- Nothing here costs money, and nothing here exists in the cloud overlays: on GKE and EKS a
  `type: LoadBalancer` Service is fulfilled by the provider. The contrast is the lesson —
  on-prem this took a pool, a policy, a beta feature and an ADR; in a cloud it is one field, and
  the bill arrives monthly, which is why ADR-0003 forbids leaving one running.

---

## Verified, 2026-10-27

Working, and the upstream risk did not materialise.

```
7/7 LoadBalancer address, announced on the node network
    allocated from pool          192.168.100.201
    answers from workstation     200  (announced by k8s-w02)

$ kubectl get leases -n kube-system | grep l2announce
cilium-l2announce-platform-ingress-cilium-gateway-platform   k8s-w02   75s
cilium-l2announce-smoke-31430-web-lb                         k8s-w02   13s

$ curl --cacert <platform-ca> https://gw.platform.local
404
```

Four things in that output are worth keeping.

**The Gateway path works on 1.20.3.** [cilium/cilium#43819](https://github.com/cilium/cilium/issues/43819)
— Gateway plus L2 announcements reachable inside the cluster and timing out from outside — was
reported against 1.18.x with no root cause, so it could have applied here. It does not. The
staged verification (plain `type: LoadBalancer` first, Gateway second) cost nothing and would
have isolated the fault in one step if it had. **The risk is retired for 1.20.3 only** — if this
cluster is ever upgraded and the Gateway stops answering from outside while step 7 still passes,
that issue is the first place to look.

**`404` is the success condition.** No HTTPRoute exists yet, so `cilium-envoy` terminating TLS
with a certificate `platform-ca` signed and then honestly reporting that it has nothing to route
to is the whole chain working. The `--cacert` is doing real work: without it curl refuses, which
is the correct behaviour toward a private CA and not a misconfiguration.

**There are two leases, one per announced address**, not one per node or one per policy. So the
announcement is per-service and Cilium elects a holder for each independently — both happen to be
`k8s-w02` here, and nothing requires them to be.

**The Gateway's generated Service is named `cilium-gateway-<gateway-name>` in the Gateway's own
namespace**, which is visible in the lease name
(`cilium-l2announce-platform-ingress-cilium-gateway-platform` = namespace `platform-ingress`,
service `cilium-gateway-platform`). Cilium's documentation does not state this, and it is the
name needed to inspect the Service directly.

### Not yet tested: failover

The policy deliberately selects both workers so that there is somewhere to fail over **to**. That
the lease *moves* when the holder dies has not been demonstrated, only made possible. Until it
is, the default 15s lease duration and 5s renew deadline are numbers from a document rather than
measured behaviour.
