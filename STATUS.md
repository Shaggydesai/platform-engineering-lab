# Where we are

> **This file is the answer to "what was I doing?"** Update it at the end of every session,
> before you close the laptop. It takes thirty seconds and it is the reason this project will
> not stall like the last one.

**Last updated:** 2026-11-01
**Current module:** 08 — GCP. Guardrail, cluster and Layer 2 written; Layer 2 not yet *run* on a
live cluster.
**Overall progress:** Modules 00–07 complete — 8 / 13

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
| **GCP cluster** | **buildable, currently destroyed** — zonal `platform` in asia-south1-a, 2× e2-medium **spot**, external IPs, Workload Identity. `make gcp-up` / `make gcp-down` / `make gcp-kubeconfig` (context `gcp-platform`) |
| **GCP NetworkPolicy** | **fixed before it mattered.** The first cluster had `datapath_provider` unset — GKE then *accepts* NetworkPolicy objects and enforces nothing, so ADR-0017's tenant policies would have reported Synced/Healthy and done nothing. Now `ADVANCED_DATAPATH` (Dataplane V2, which is managed Cilium). **Cannot be changed in place** — it forces cluster replacement, so going in between a destroy and the next create was free |
| **GCP Layer 2** | **written, not yet run on a cluster.** `make gcp-argocd` runs the *same* `ansible/roles/argocd` as on-prem against the `gcp-platform` context (ADR-0020). One-play playbook, one-host inventory — there is no node on GKE to log into. Platform set: the canary + cert-manager. `make gcp-smoke` reads back what the cluster actually is |
| **GCP costs while up** | **~₹3/hour** — 2 spot nodes, 2 external IPv4, 64 GB pd-standard. ~₹70 if left overnight. `make gcp-down` ends it; `make cost-check` proves it |
| **Kubernetes versions DIFFER** | on-prem **v1.34.12**, GKE **v1.36.4**. Two minors. Measured, not chosen — see ADR-0019's verified section. First concrete entry for Module 09's "six differences" |
| **GCP guardrail** | ₹400 budget `ad4e1d32`, thresholds 50/90/100%, verified against the API. **`make gcp-up` refuses to run without it** |
| **GCP account** | project `platform-eng-lab-261031`, billing `01662D-…-2D203C` linked. **Free trial: ₹28,257 of ₹28,797 left, ends 2027-01-02.** After that date the same mistake bills a card. Console still shows an unactioned **"administrator must verify this account"** banner |
| **GCP leftovers** | **cleaned 2026-11-01.** The old `shopverse-lab` project is deleted, taking its tfstate bucket, Vault bucket and KMS keyring with it; the two stray ₹2500 budgets are gone. `make cost-check` clean |
| **AWS cluster** | not built |
| **Argo CD** | **running** — chart 10.11.0 / Argo CD v3.5.5, root app Synced, self-heal verified |
| **Platform components** | metrics-server 3.14.0, cert-manager v1.21.3 + internal PKI — both Synced/Healthy |
| **Internal CA** | `platform-ca` ClusterIssuer, Ready. Root valid to **2036-10-21**, key in `cert-manager/platform-ca-tls` |
| **ShopVerse running** | **yes** — `https://shopverse.platform.local`, 8 pods, 20 seeded products, MongoDB on a 5Gi `platform-local` volume |
| **Tenant isolation** | **enforced** — only 5 named services may reach MongoDB (ADR-0017). `make netpol-check` proves it: two pods one label apart, one connects, one does not |
| **ShopVerse gate** | `make shopverse-check` passes: register → cart → checkout → delete MongoDB → order survives, same PV |
| **Everything pinned** | **yes** — images `sha-6fd8524` (all 7 verified by digest against what is running), app chart by commit, Gateway API by SHA-256, charts by version. No moving references left |
| **Secret backend** | **Vault 2.0.4** (chart 0.34.1), standalone, file storage on a 2Gi `platform-local` PVC. **Sealed after every cluster restart** — `make vault-unseal` |
| **Secrets reach pods** | **External Secrets 2.14.0.** `ClusterSecretStore/vault-backend` Ready; ShopVerse's six credentials arrive via an ExternalSecret that names no substrate (ADR-0018) |
| **Secrets in Git** | **none.** `make secrets-audit` searches every commit on every ref for the live values — the tenant's and Vault's root token and unseal keys |
| **etcd encryption** | **on, and all 17 Secrets rewritten** — `k8s:enc:aescbc:v1:key1` in etcd, verified by reading etcd. `make etcd-encryption-check` |
| **Irreducible secrets** | **two, both outside Git.** `.cache/vault-init.json` (workstation) and `/etc/kubernetes/enc/key1.b64` (control plane). Losing either is unrecoverable — see ADR-0018 and the parking lot |
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

**One command, and it needs the laptop.** Everything for Layer 2 on GKE is written, linted and
committed; nothing has touched a live cluster. In order, in one sitting of about twenty minutes:

```bash
make gcp-guardrails          # needs TF_VAR_billing_account, or .cache/gcp-billing-account
make gcp-up                  # ~9 min. REFUSES if the guardrail is missing or unverifiable
make gcp-kubeconfig          # creates the gcp-platform context
make gcp-argocd              # the SAME ansible role as on-prem (ADR-0020)
make gcp-smoke               # reads back what the cluster IS, including the negatives
make gcp-down && make cost-check    # ADR-0003 Decision 5. Not optional
```

**The six claims `gcp-smoke` settles**, all currently unverified because they need a cluster:
the role installs Argo CD on GKE; the seam applies; `platform-gcp` reaches Synced/Healthy; the
canary ConfigMap appears (which proves the whole Layer 2 chain on a second substrate); cert-manager's
CRDs apply with ServerSideApply on this datapath; and GKE's own metrics-server serves `kubectl top`
**without** us installing one — including the negative check that no `metrics-server` Application
exists here, because two of them conflict over a cluster-scoped APIService with no error message.

Cost for that sitting: roughly **₹3–6** (2 spot nodes, 2 external IPv4, 64 GB pd-standard, under
an hour), against ₹28,257 of trial credit.

### Still open in Module 08, after that

- **External Secrets against GCP Secret Manager.** The overlay is written and needs three values
  from `terraform output` (project, cluster name, zone), a Google service account, an IAM binding
  and the six credentials in Secret Manager. Six secret versions is inside the free tier.
- **Ingress.** No Application, on purpose: a `type=LoadBalancer` Service here bills monthly, which
  ADR-0003 forbids leaving running. GKE Gateway is a different implementation of the same contract
  and deserves its own module rather than a corner of this one.
- **The ACME ClusterIssuer is cancelled, not deferred.** The overlay promised publicly trusted
  certificates via DNS-01 against Cloud DNS. That needs a public zone (~$0.20/month — a standing
  charge ADR-0003 forbids) and a domain this project does not own. cert-manager is installed and
  issues nothing; the correction is written into the overlay above the original sentence.

### Two older debts, both cheap and already scoped

1. **Module 06's browser half.** `make shopverse-check` passes with a CA that `curl` verifies,
   but the roadmap's bar says a *browser* trusting it. That means importing `platform-ca` into
   the Windows trust store — a change to a machine, not to this repository — and it is untested
   whether Windows can even reach `192.168.100.*` from WSL2. `docs/runbooks/06-shopverse.md` has
   the steps.
2. **The on-prem PKI gaps, which belong to no module yet.** Two parking-lot entries: Vault's API
   is plaintext HTTP (`tls_disable = 1`, mitigated by a NetworkPolicy and nothing else), and
   External Secrets runs its own CA for its own webhook. Both are a Certificate plus a values
   change, since `platform-ca` already exists, and together they would make "everything in this
   cluster that presents a certificate got it from `platform-ca`" true — currently false in three
   places counting metrics-server.

   **An earlier version of this file called that "Module 08's opening move". It is not.** The
   roadmap says Module 08 is GCP; the attribution came from parking-lot entries written here and
   then believed on a later read. They need a named module in `docs/roadmap.md` or they will keep
   drifting to whichever one is next.

**Before AWS (Module 09): the $5 budget alarm**, which ADR-0003 requires to exist *before* the
first cloud resource. The GCP ₹400 one exists and is verified against the API; the AWS one does
not exist at all. That is not a suggestion in the roadmap, it is the thing standing between this
project and a bill.

## Module 07 closed, 2026-10-31

Four stages, all verified, and ADR-0018 carries the evidence for each.

**Vault + External Secrets** (ADR-0018). The deciding argument was portability and it held: the
ExternalSecret manifest names a store and a key and nothing else, so the same object works on
GKE and EKS with twelve lines of provider changing in an overlay. `gcp` and `aws` overlays are
written and deliberately still call the store `vault-backend`, because the name is the contract a
tenant writes against rather than a description of the implementation.

**The six credentials were copied, never regenerated.** `mongo-password` initialised MongoDB's
root user on first boot only, so a fresh value would have left seven services authenticating
against a database that still expected the old one — presenting as a Running, Ready MongoDB
refusing every connection. `make vault-seed-shopverse` copies from the cluster, verifies each
value by a hash computed inside the Vault pod, and proves ESO can read them back through a
throwaway ExternalSecret *before* anything is flipped.

**Both of the roadmap's bars got an honest answer, and only one is met.**

- *"git grep finds no credential"* — **met**, and `make secrets-audit` is the standing proof.
  Verified by planting a live credential in a commit and watching it fail.
- *"rotating one secret takes one commit"* — **not met, and the bar was wrong.** With Vault and
  ESO rotation takes zero commits, because the value is not in Git. It takes a Vault write, a
  forced refresh, and a rollout — the last because all six values are `secretKeyRef` env vars,
  resolved once at pod creation, so ESO updating the Secret changes nothing about a running pod.
  And `mongo-password` cannot be rotated at all without deleting the volume.

**The blast radius of a secret change is narrower than the release.** Flipping
`externalSecret.enabled` replaced six of eight pods; `shopverse-frontend` and
`shopverse-api-gateway` kept running, because the chart gates the credential env vars on
`$svc.mongoDatabase`. That set is exactly the five services Hubble saw reaching MongoDB in
ADR-0017 plus MongoDB itself — two questions asked independently, one boundary.

**etcd encryption, with the step everyone skips.** 1 of 17 Secrets was encrypted before
`make etcd-reencrypt` and 16 were not: enabling encryption reaches forward only. Now 17 of 17,
confirmed by reading ciphertext out of etcd rather than by reading a flag.

### What this module cost in mistakes, because the pattern is the point

Nine instances now of one failure shape — **a check that confirms a request was recorded rather
than that it took effect.** This module added four: a `kubernetes_host` read back and printed
without being asserted (it said `https://:`); `kubectl auth can-i create serviceaccounts/token`,
which asks whether you may create a ServiceAccount *named* token and answered no about a
permission that was present; a NotReady ClusterSecretStore read once during ESO's exponential
backoff and called broken; and an API-server wait that would have passed on the old process still
answering.

Two new shapes joined the collection:

- **a check whose "no" does not mean no.** The `auth can-i` false negative became the leading
  hypothesis for an unrelated failure and cost an hour. Every such check now has three outcomes —
  yes, no, and NOT KNOWN — because a check that cannot get an answer must not report a denial.
- **a fix applied to the instance, leaving the class.** `--check` broke `control_plane`; I fixed
  it there and the identical bug was waiting one role away in `etcd_encryption`.

And one bug that no failing run would have shown: running the encryption tasks for real against a
temp directory produced `key1.b64` at **mode 0644** — the key to every Secret in etcd,
world-readable. The check-mode failure that prompted the fix never created a file, so it could not
have surfaced it. Two bugs in the same five lines; the failure reported exactly one.

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

