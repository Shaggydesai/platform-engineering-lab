# Learn

**Written material, not links.** `docs/reading.md` is the map to primary sources — read that when
you want the vendor's own reference. This directory is the thing you can read start to finish
without leaving the repository.

The difference matters. Vendor documentation describes a product working. These chapters describe
**the mechanism**, and then **what it actually did on this cluster** — including the places where
the documented behaviour and the observed behaviour were not the same thing, which is most of what
this lab has learned.

Every chapter is written to be read on its own, in order, with no tabs open.

---

## How to read a chapter

Each one has the same four parts, deliberately:

1. **The problem** — what goes wrong if this component does not exist. Always first, because a
   mechanism learned without its problem is a mechanism you cannot reason about later.
2. **The mechanism** — how it actually works, at the level of "what process writes what, where".
   Not configuration options; those are in `reading.md`'s links and they change.
3. **In this lab** — the specific files, values and commands, with the real output.
4. **What bit us** — the mistakes, with what the wrong belief was and what disproved it. These are
   drawn from `docs/parking-lot.md`, which is the honest record; the chapters just explain them.

Commands in part 3 are runnable. Where a chapter shows output, it is output from this cluster, not
an illustration.

---

## The chapters

| # | Chapter | What you can do afterwards |
|:--|:--|:--|
| 01 | [What a Kubernetes cluster is made of](01-cluster-anatomy.md) | Name every process on a node and say what breaks without it. Read `kubeadm init`'s output and know what each phase wrote to disk. |
| 02 | The substrate: virtual machines and images | Explain why a node is built from an image rather than configured, and what cloud-init does that Packer cannot. |
| 03 | Ansible as assertion | Tell the difference between a playbook that configures and one that asserts, and say why this project's `preflight` role refuses to do the former. |
| 04 | [Pod networking, eBPF, and life without kube-proxy](04-pod-networking.md) | Trace a packet from one pod to another, say where a Service's address is translated, and read `cilium-dbg service list` instead of guessing from `iptables-save`. |
| 05 | Services, and how traffic reaches a cluster from outside | Explain ClusterIP vs NodePort vs LoadBalancer in terms of *who answers ARP*, and why an on-prem LoadBalancer needs a lease. |
| 06 | Ingress and the Gateway API | Write a `Gateway` and an `HTTPRoute`, and know what `sectionName` prevents. |
| 07 | Certificates, private CAs, and cert-manager | Say what a certificate actually proves, and why this lab has a CA of its own. |
| 08 | GitOps: reconciliation, and what Argo CD does not own | Explain drift, pruning, sync waves — and the class of object Argo CD will never delete. |
| 09 | Secrets: at rest, in transit, and who holds the key | Describe what etcd encryption protects against and what it does not, and name the two secrets in this project that cannot be regenerated. |
| 10 | Network policy and identity | Write a policy that denies by default without breaking DNS, and read a Hubble verdict. |
| 11 | Storage: volumes, CSI, and the orphan problem | Say who owns a PVC, and why a clean `terraform destroy` can leave a disk billing. |
| 12 | Three substrates: laptop, GKE, EC2 | Say what "managed" actually removes, and what it takes away with it. |
| 13 | Cost, guardrails, and teardown | Explain why a budget alarm is not a spend cap, and what the only real control is. |

**01 and 04 are written.** The rest are titles in that table with no link, deliberately: an
unwritten chapter is not a link that 404s and not a stub that pretends to be a chapter. They get
links when they have content. `make lint` checks that every link in here resolves, so a title
cannot quietly become a broken promise.

Order of writing, by what unlocks the most: **05** (services and L2 — finishes the networking
arc), **10** (network policy and identity — the evidence is fresh and the story is complete), then
**08** (GitOps), **09** (secrets), and the rest.

---

## Why this lives in the lab repository

A separate repository was the obvious alternative and is worse, for one reason: **these chapters
quote this repository's files, values and check output.** In here, a chapter that says
`cilium-values.yaml sets kubeProxyReplacement: true` sits next to the file, is versioned with it,
and shows up in the same diff when it changes. Split across two repositories, the chapter is
correct on the day it is written and silently wrong three commits later — which is the exact
failure mode `docs/parking-lot.md` is mostly made of, and it would be absurd to build it into the
material explaining that.

If it grows past the point where that is a good trade, splitting is a `git filter-repo` away and
the chapters would need their own cross-reference check first.
