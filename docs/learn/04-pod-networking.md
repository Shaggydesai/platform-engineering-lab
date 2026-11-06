# 04 — Pod networking, eBPF, and life without kube-proxy

> Chapter 01 left two address ranges on the table: `10.244.0.0/16` for pods and `10.96.0.0/12` for
> Services, with the claim that only the first kind is real. This chapter follows a packet through
> both and shows you the tool that tells the truth about it.

---

## 1. The problem

Kubernetes requires three things of a network, and they are strict enough that no standard Linux
setup provides them out of the box:

1. **Every pod gets its own IP address**, and containers in a pod share it. Not a port on the
   node — an address. So two pods can both listen on 8080 and never collide.
2. **Every pod can reach every other pod directly, without NAT.** The address a pod sees as the
   source is the address the sender actually has. This is called the *flat network* requirement and
   it is the one that rules out the simplest designs.
3. **Nodes can reach pods, and pods can reach nodes**, again without translation.

Nothing in that list is about Services, load balancing or policy. Those come later and are built on
it. The baseline requirement is: a flat, NAT-free address space spanning machines that each have
only one real network interface.

Then separately: **a pod's address is useless to write down.** Pods are replaced constantly, and a
replacement gets a new address. So you also need a stable name and address that survives
replacement, which routes to whichever pods currently exist. That is a Service, and it is a
genuinely different problem solved by a genuinely different mechanism.

---

## 2. The mechanism

### 2.1 How a pod gets an address

When the kubelet is told to run a pod, it does **not** configure networking. It calls a binary in
`/opt/cni/bin` with a JSON blob on stdin, and expects an address back. That interface is CNI.

The plugin — Cilium here — does roughly this:

1. Creates a network namespace for the pod.
2. Creates a `veth` pair: a virtual cable with two ends. One end goes inside the pod's namespace
   and becomes its `eth0`; the other stays in the host namespace.
3. Picks an address from the range allocated to **this node** and assigns it to the pod end.
4. Writes routes so the host knows that address lives down that particular veth.
5. Attaches eBPF programs to the host end (more on this below).

The per-node allocation is the important structural idea. The cluster has `10.244.0.0/16`; each
node is given a `/24` out of it and hands addresses out locally without coordinating with anything.
This lab's configuration says so explicitly:

```yaml
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList: [10.244.0.0/16]
    clusterPoolIPv4MaskSize: 24      # 254 pods per node, up to 256 nodes
```

So `k8s-w01` might own `10.244.1.0/24` and `k8s-w02` `10.244.2.0/24`. Routing between nodes then
only needs to know "the `/24` for this node is over there" rather than tracking individual pods —
which is what makes the flat requirement tractable.

### 2.2 Getting a packet between nodes: the two honest options

Node A's pod wants to reach node B's pod. The nodes are on `192.168.100.0/24`; the pods are on
`10.244.x.0/24`. The physical network has never heard of `10.244.0.0/16` and will not route it.

**Option one: tell the network.** Add routes, or speak BGP to the switches, so the infrastructure
itself knows `10.244.1.0/24` is behind `192.168.100.11`. Fast — packets are forwarded natively,
nothing is wrapped — but it requires the network to cooperate, which on a laptop's libvirt bridge
or inside a cloud VPC it generally will not.

**Option two: encapsulate.** Put the pod-to-pod packet *inside* a node-to-node packet. The
physical network sees ordinary traffic between two node addresses and routes it normally; the
receiving node unwraps and delivers. This needs nothing from the network at all.

This lab takes option two:

```yaml
routingMode: tunnel
tunnelProtocol: vxlan
```

**VXLAN** wraps the original Ethernet frame in UDP, on port 8472. The cost is about 50 bytes of
header per packet and a little CPU; the benefit is that it works on any network that can carry UDP
between nodes — which is precisely why the same configuration works on a libvirt NAT network and
inside an AWS VPC without changing a line.

This is also why `terraform/aws/main.tf` opens **all** traffic between the nodes' own security
group rather than enumerating ports. Guess the port list and you will forget 8472/udp, and the
symptom is a cluster where pods on the same node talk and pods on different nodes do not — which
looks like a broken application.

### 2.3 Services: a virtual address and the translation behind it

A Service gets an address from `10.96.0.0/12`. **Nothing holds that address.** No interface has
it, nothing answers ARP for it, and if you tcpdump for it on the wire between nodes you will not
see it. It exists as a rule: *when a packet is sent to 10.96.x.y:80, rewrite the destination to one
of these pod addresses.*

Where that rewrite happens is the whole question.

**The traditional answer: kube-proxy.** It watches Services and Endpoints and programs **iptables**
(or IPVS) on every node — a chain per Service, a rule per backend, with statistical matching to
spread connections. It works and it is well understood. Two costs:

- iptables is evaluated as an ordered list, so the cost of a lookup grows with the number of rules.
  A few thousand Services produces tens of thousands of rules and a measurable per-packet cost.
- Rule updates are not incremental in the classic implementation, so churn is expensive.

**The answer this lab uses: eBPF, and no kube-proxy at all.**

```yaml
kubeProxyReplacement: true
```

eBPF lets a program be loaded into the running kernel and attached to a hook — on a network
interface, on a socket operation, at various points in the stack. It is verified before loading
(bounded loops, no arbitrary memory access) so a buggy program cannot panic the kernel, and it can
read and write **maps**: key-value tables shared between the kernel program and userspace.

So Cilium puts the Service table *in a map*. A packet to a Service address is a **hash lookup**,
not a list traversal, and the cost does not grow with the number of Services. Adding a backend is
one map entry, not a rule-set regeneration.

The consequence for operating the cluster is the part that matters:

> **`iptables-save` no longer tells you anything about Services.** The rules are not there. They
> are in eBPF maps, and the tool that reads them is `cilium-dbg`.

This lab learned that as a bug rather than as a fact: a check that counted `KUBE-SVC` iptables
rules to decide whether Services worked was reading the wrong tool, and would have reported the
same thing on a healthy cluster and a broken one. `make netpol-check` now says it in its own
output:

```
aws-cp01: KUBE-SVC iptables rules 0 -> 0. Service lookups now happen in eBPF
maps: kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
```

### 2.4 The bootstrap problem this creates

kube-proxy is what normally programs the address of the Kubernetes API Service itself
(`10.96.0.1`). Remove kube-proxy and Cilium is responsible for it — but **Cilium's own agent needs
to reach the API server to start**, and at that moment nothing has programmed `10.96.0.1`.

So the agent needs a real address, given to it directly:

```yaml
k8sServiceHost: k8s-cp01.platform.local
k8sServicePort: 6443
```

Not a Service address. A name (or an address) resolving to the control plane itself, bypassing the
Service abstraction entirely.

**This single value is the one line of this lab's CNI configuration that is not portable**, and it
broke the AWS substrate: `k8s-cp01.platform.local` exists only in the libvirt nodes' `/etc/hosts`,
so on EC2 the agent could not reach the API server at all, the DaemonSet never became available,
and the only symptom was `rollout status` timing out after 180 seconds with no cause given. There
is no fallback, by construction: kube-proxy is gone, and Cilium is the thing that would have
programmed the address it would have fallen back to.

### 2.5 Hubble: seeing the decisions

Because the datapath is a program rather than a rule list, it can report on itself.

```yaml
hubble:
  enabled: true
  relay:
    enabled: true
```

Hubble emits a flow record per decision, with the **identities** involved (chapter 10) and the
verdict — `FORWARDED`, `DROPPED`, and for policy specifically `policy-verdict:...ALLOWED` or
`DENIED`. This is not logging in the usual sense; it is the datapath telling you what it did and
why, and it is the only reason chapter 10's story about network policy has a definite answer rather
than a theory.

One practical trap, which cost this lab an hour:

> **`kubectl -n kube-system exec ds/cilium -- hubble observe ...` picks one arbitrary agent pod,
> and an agent only sees flows on its own node.** On a three-node cluster, asking the wrong agent
> returns silence that reads exactly like "nothing was dropped".

Five of this repository's own diagnostic hints had that bug, all copied from the first one. They
now resolve the agent on the target pod's node first:

```bash
AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium \
  --field-selector spec.nodeName=$(kubectl -n NS get pod POD -o jsonpath='{.spec.nodeName}'),status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec "$AGENT" -- hubble observe --to-pod NS/POD --last 20
```

The `status.phase=Running` is not pedantry either: during an agent restart the old pod lingers in
`Terminating`, and `items[0]` can be the one that is shutting down — which returns an empty buffer
and looks, again, like nothing happened.

---

## 3. In this lab

### 3.1 Following a packet, with the real tools

```bash
# 1. Pod addresses are real. Each is in its node's /24.
kubectl -n shopverse-prod get pods -o wide

# 2. The Service address is not. Nothing holds it.
kubectl -n shopverse-prod get svc shopverse-frontend
#   CLUSTER-IP   10.96.x.y        <- no interface anywhere has this

# 3. Where the translation lives. NOT iptables.
AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium \
        --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec "$AGENT" -- cilium-dbg service list

# 4. Proof there is nothing in iptables to find
kubectl -n kube-system exec "$AGENT" -- iptables-save | grep -c KUBE-SVC || echo 0

# 5. The agent's own view of what it is doing
kubectl -n kube-system exec "$AGENT" -- cilium-dbg status --verbose | head -30
```

Step 5 prints `KubeProxyReplacement: True` along with the devices it has attached eBPF programs to.
That line is what `make onprem-cluster` asserts rather than assumes — the `cilium` role reads it
back from every agent and reports `all N agents running kubeProxyReplacement=true`, because a helm
release that *says* `true` and an agent that is *running* `true` are two different claims.

### 3.2 Why that distinction earned its own task

The `cilium` role has a sequence that looks over-engineered until you know what it is for:

```
What configuration do the values ASK for?
What configuration are the agents actually RUNNING?
When was the configuration last written, and when did the agents start?
Are the agents older than the configuration they are supposed to be running?
Decide whether a restart is needed
Why a restart is or is not happening
```

Cilium reads much of its configuration from a ConfigMap **at startup**. Change the helm values and
the ConfigMap updates immediately; the running agents keep their old settings until restarted. So
a cluster can be in a state where Git, helm and the ConfigMap all agree on
`kubeProxyReplacement: true` and the agents are still doing something else — and every check that
reads configuration rather than behaviour passes.

Hence the timestamp comparison: config written at `T1`, oldest agent started at `T0`, and if
`T0 < T1` the agents are running something older than what they were told. The role prints its
reasoning:

```
restart=True (helm changed=True, config written=2026-11-05T10:26:43Z, oldest
agent=2026-11-05T10:26:44Z, modes=true)
```

### 3.3 The CIDR agreement nothing was checking

Cilium's operator hands out pod addresses from its own configured pool. kube-controller-manager was
told a `podSubnet` by kubeadm. **Nothing made those agree.**

If they disagree, there is no error anywhere: pods get addresses from one range while the cluster
believes another, and the symptom is pods that cannot be reached. `make lint` now compares every
`clusters/*/*.json` pod CIDR against the pool in `cilium-values.yaml` — and the gap before that was
instructive, because lint *did* already check that the two substrates agreed **with each other**,
which is not the same as either agreeing with the file the operator actually reads.

---

## 4. What bit us

**`k8sServiceHost` was a hostname only one substrate had.** The full story is §2.4. What makes it
worth re-reading: the file's own comment had flagged the value as load-bearing in Module 04 —
*"THIS IS NOW LOAD-BEARING"* — without noticing it was a name that existed in exactly one place.
The comment was right about the importance and blind to the portability, and nothing could reveal
that until the same file was used on a second substrate.

**A check that counted iptables rules.** Reading `iptables-save` to decide whether Services work,
on a cluster whose Services are in eBPF maps, is a check that asks a different question from the
one intended. It would pass identically on a working cluster and a broken one. This is the first
recorded instance of what became the repository's most common bug shape, and `cilium-dbg service
list` is the tool that answers the actual question.

**Counting objects instead of asking whether they took effect.** Three separate times: counting
`HTTPRoute` objects and calling them attached, counting policy objects and calling them enforced,
counting iptables rules and calling Services programmed. All three have the same fix — read the
*status* the controller wrote, not the *existence* of the thing you created.

**An agent that only sees its own node.** §2.5. The reason it is in this chapter rather than only
in the parking lot is that it is a property of the architecture: the datapath is per-node, so the
observability is per-node, and any tool that forgets this answers for one third of the cluster
while appearing to answer for all of it.

---

## Next

Chapter 05 — Services, and how traffic reaches a cluster from outside — takes the Service
abstraction from §2.3 and asks the question this chapter dodged: if nothing answers ARP for a
Service address, what happens when the address is supposed to be reachable from *outside* the
cluster?

Primary sources: `docs/reading.md`, the ADR-0007/ADR-0012 row — *kube-proxy replacement* and *eBPF
datapath* in the Cilium docs are the two worth reading in full.
