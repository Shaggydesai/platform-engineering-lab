# Where we are

> **This file is the answer to "what was I doing?"** Update it at the end of every session,
> before you close the laptop. It takes thirty seconds and it is the reason this project will
> not stall like the last one.

**Last updated:** 2026-10-27
**Current module:** 06 — ShopVerse runs (serving, gated and pinned; the browser half remains)
**Overall progress:** Modules 00–05 complete — 6 / 13

---

## Right now

| | |
|:--|:--|
| **On-prem nodes** | **built and verified** — k8s-cp01 .10, k8s-w01 .11, k8s-w02 .12, destroy/apply round trip passes |
| **On-prem cluster** | **running, and rebuildable from nothing in ~4 minutes** — 3 nodes, v1.34.12, Cilium 1.20.3 |
| **Dataplane** | **no kube-proxy.** All 3 agents `KubeProxyReplacement: True`, 0 `KUBE-SVC` iptables rules, Services in eBPF maps. `cilium-dbg service list`, not `iptables-save` |
| **Gateway API** | CRDs v1.6.3, pinned by digest `356c2b8e…`. `gatewayclass/cilium` **Accepted=True** |
| **LoadBalancer addresses** | **working** — pool `192.168.100.200–.239`, announced by a worker over ARP (ADR-0013) |
| **Gateway** | **working** — wildcard listener `*.platform.local` at `.200`, HTTPS terminated with a `platform-ca` certificate |
| **Argo CD UI** | `https://argocd.platform.local` through the Gateway (ADR-0014). `make argocd-ui` port-forward stays as the recovery path |
| **Ingress failover** | **measured: ~15s** on a hard node power-off, bounded by the L2 lease duration (ADR-0013) |
| **Storage** | **working** — local-path-provisioner v0.0.37, default class `platform-local` (ADR-0015). Node-local: a dead node takes its data with it |
| **Certificates expire** | **2027-10-22** — `sudo kubeadm certs renew all` before then, or nothing works |
| **GCP cluster** | not built — account verified empty, ₹0 running |
| **AWS cluster** | not built |
| **Argo CD** | **running** — chart 10.11.0 / Argo CD v3.5.5, root app Synced, self-heal verified |
| **Platform components** | metrics-server 3.14.0, cert-manager v1.21.3 + internal PKI — both Synced/Healthy |
| **Internal CA** | `platform-ca` ClusterIssuer, Ready. Root valid to **2036-10-21**, key in `cert-manager/platform-ca-tls` |
| **ShopVerse running** | **yes** — `https://shopverse.platform.local`, 8 pods, 20 seeded products, MongoDB on a 5Gi `platform-local` volume |
| **Tenant isolation** | **enforced** — only 5 named services may reach MongoDB (ADR-0017). `make netpol-check` proves it: two pods one label apart, one connects, one does not |
| **ShopVerse gate** | `make shopverse-check` passes: register → cart → checkout → delete MongoDB → order survives, same PV |
| **Everything pinned** | **yes** — images `sha-6fd8524` (all 7 verified by digest against what is running), app chart by commit, Gateway API by SHA-256, charts by version. No moving references left |
| **Monthly spend** | ₹0 |

To bring the nodes back after a reboot or a `wsl --shutdown`:

```bash
make onprem-vms            # idempotent; recreates only what is missing
make onprem-vms-status
```

## Module 05 closed, 2026-10-29

Gate met on both counts the roadmap asks for.

**The platform app-of-apps is fully Synced and Healthy on on-prem** — five Applications:
`gitops-canary`, `metrics-server`, `cert-manager`, `platform-ingress`, `local-path`.

**The overlay mechanism is proven by values that genuinely differ per environment**, not by
placeholders: `platformPKI.enabled` (on-prem only, ADR-0011), the whole of `platform-ingress`
(a pool and an ARP policy that would claim addresses a cloud provider owns, ADR-0013), and
`local-path` (no counterpart at all where the provider ships a default StorageClass, ADR-0015).

`make onprem-up` reports `changed=0`, `make smoke` passes 7 of 7, and the seam's phantom
re-apply is gone.

## The next action

**Module 06 — ShopVerse runs.** The platform gets its tenant, and the roadmap's bar is a
behavioural one rather than a status one: open the storefront over HTTPS with a certificate the
browser trusts, add an item to the cart, complete a checkout, and have the order survive a pod
restart.

Everything it needs now exists. A name on the Gateway is an HTTPRoute plus an `/etc/hosts` line
(ADR-0014). A PVC with no storageClassName gets `platform-local` (ADR-0015). TLS comes from
`platform-ca` — and "a certificate the browser trusts" is the one part that needs a decision,
because trusting it means importing the CA into the OS store, which is a change to a machine
rather than to this repository.

Two things to settle first:

1. **The `tenants` AppProject has never been used.** It restricts destinations to `shopverse-*`
   and blacklists cluster-scoped resources entirely. ShopVerse is the first thing to test
   whether those limits are right or merely strict — and the first Application to go into a
   different project than `platform`.
2. **Secrets.** MongoDB needs credentials and Module 07 is where secrets get solved properly.
   Doing Module 06 first means a credential exists somewhere for a module's length; the honest
   options are to generate it in-cluster and never put it in Git, or to reorder the modules.

## Verified on 2026-10-27

- `make smoke` **6 of 6**, including the new step 6: NodePort answered on all three nodes from
  the workstation, with the two forwarded hops (no local backend) marked as such.
- `make onprem-up` **changed=0** on all three nodes — the Module 03 gate still holds with the
  CNI, the Gateway API CRDs and the kube-proxy removal all in the playbook.
- `make hosts` reconciles stale SSH host keys after a VM rebuild, so the man-in-the-middle
  warning means something again.

## Answered, partly

**The Argo CD seam's phantom re-apply is fixed** (2026-10-29). `root-onprem.yaml` stated
`directory.recurse: false`; the saved diff showed the live object missing that field while our
manifest had it. The line is removed and the oscillation stops.

**The mechanism is not established.** My first explanation — that the API server could never
store the field — was disproved by the very next run, which found it present in the live object
and removed it. Something drops it between applies; an omitempty round-trip is a suspect, not a
finding. Not chased further because the fix does not depend on it.

One real cost, recorded in `docs/parking-lot.md`: non-recursion now relies on `false` staying
Argo CD's default, so re-check that on any Argo CD upgrade.

The diff-capture task in the `argocd` role found this on its first real run. Two sightingshad produced a parking-lot entry and no knowledge; one saved diff produced the cause.

