# Where we are

> **This file is the answer to "what was I doing?"** Update it at the end of every session,
> before you close the laptop. It takes thirty seconds and it is the reason this project will
> not stall like the last one.

**Last updated:** 2026-11-01
**Current module:** 08 — GCP. Guardrail, cluster, Layer 2 and the secret backend are **applied
and verified**. The tenant and the ingress decision are **written but never run**.
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
| **GCP cluster** | **buildable, currently destroyed** — zonal `platform` in asia-south1-a, 2× **e2-standard-2** spot (was e2-medium — see below), external IPs, Workload Identity. `make gcp-up` / `make gcp-down` / `make gcp-kubeconfig` (context `gcp-platform`) |
| **GCP NetworkPolicy** | **fixed before it mattered.** The first cluster had `datapath_provider` unset — GKE then *accepts* NetworkPolicy objects and enforces nothing, so ADR-0017's tenant policies would have reported Synced/Healthy and done nothing. Now `ADVANCED_DATAPATH` (Dataplane V2, which is managed Cilium). **Cannot be changed in place** — it forces cluster replacement, so going in between a destroy and the next create was free |
| **GCP Layer 2** | **done and verified, 2026-11-01.** `make gcp-argocd` runs the *same* `ansible/roles/argocd` as on-prem against `gcp-platform` (ADR-0020): 27 ok, 0 failed. Argo CD v3.5.5, root app `platform-gcp` Synced/Healthy, `cert-manager` and `gitops-canary` both Synced/Healthy. One-play playbook, one-host inventory — there is no node on GKE to log into |
| **ADR-0001's premise, tested** | **holds at Layer 3.** The canary rendered from the *same* directory on-prem renders, no overlay, `generation=2` matching Git. cert-manager rendered from the *same* wrapper chart with one path segment different — on-prem a self-signed root CA and three certificates, GKE nothing at all. One definition, two trust models |
| **GCP smoke** | `make gcp-smoke` — `ADVANCED_DATAPATH`, **no control-plane node**, metrics served by GKE's own plus the negative check (no `metrics-server` Application of ours). On 2026-11-02 it found the capacity failure and now prints the scheduler's own reason plus allocatable-vs-requested per node |
| **The capacity failure** | **`e2-medium` is SHARED-CORE** — 2 vCPU nominal, **one guaranteed**, 940m allocatable, and the scheduler does not schedule against burst. Two nodes gave 1880m; 1870m was requested; 6 of 8 tenant pods `Pending`. ADR-0016's estimate was wrong by **2.05×** because the input was a machine type, not the arithmetic. Now `e2-standard-2` |
| **The laptop was bigger than the cloud** | on-prem 3 × 2 **dedicated** vCPU ≈ 6 vCPU schedulable; GKE had **1.88**. Not an argument about clouds — an argument about reading the machine type rather than the marketing number |
| **GCP secret backend** | **APPLIED and verified, 2026-11-01.** `terraform/gcp/secrets` — a service account, `secretAccessor` **on the secret not the project**, a Workload Identity binding, and ONE Secret Manager secret holding all six credentials as JSON. All six seeded and hash-matched on the round trip; `make gcp-secrets-verify` passes 5/5. **This is the first GCP resource that deliberately stays up between sessions**, at ₹0 |
| **The portability claim, settled** | ShopVerse's own ExternalSecret uses **one `remoteKey` + six `property` lookups**, so the tenant's manifest is identical on both substrates and ONE value differs: `shopverse/prod` → `shopverse-prod`. The slash is the whole difference, forced by Secret Manager IDs matching `[A-Za-z0-9_-]+` (ADR-0018 amendment) |
| **GCP secret cost** | **₹0, at one version of six free.** Secret Manager bills $0.06/version/month above six; one JSON secret uses one. Watched in **two** places now: `gcp-secrets-verify` fails at seven, and `make cost-check` counts versions per project **and account-wide** — because 4 + 4 across two projects is 8 against a billing-account quota and every per-project line would read clean. **Disabling a version is not enough — it must be destroyed** |
| **ShopVerse on GKE** | **run, and it failed usefully.** `resource :Namespace is not permitted in project tenants` — a tenant may not create its own namespace, and `CreateNamespace=true` had been asking for exactly that on BOTH substrates since Module 06. It never failed on-prem because `make shopverse-secret` created the namespace by hand first. **Fixed on both**: the namespace is a platform-owned manifest in sync wave -20, no finalizer, `prune: false`. **Re-run 2026-11-02: it works** — the namespace carries `argocd.argoproj.io/tracking-id` starting `tenant-namespaces:`, and `shopverse` is Synced/Healthy. A manual step was masking a design error, and removing the manual step is what found it |
| **An on-prem hole this exposed** | `shopverse-prod` on the laptop has been **unmanaged by Argo CD for five modules** — created by hand, never in Git, a quiet ADR-0002 Rule 3 violation. A namespace is invisible once it exists, so there was no symptom. The next on-prem sync adopts it |
| **ShopVerse on GKE, as written** | **run and working, 2026-11-02** — all 8 pods Running across both nodes, the volume Bound on `standard-rwo`, the six keys delivered by External Secrets. Same chart, same commit, same seven images; `gitops/environments/gcp/shopverse.yaml` + `gitops/clusters/gcp/apps/shopverse.yaml` + a third seam file. **Four values differ and two of them are the same text** — `ingress: false` is a no-op on-prem and a standing charge here; `storageClass: ""` is a node-local directory there and a network Persistent Disk here (ADR-0016 amendment) |
| **The `tenants` AppProject** | **travelled unedited.** Its destinations name `shopverse-*` and the in-cluster address, so the boundary ports: no cluster-scoped resources, no ResourceQuota/LimitRange/NetworkPolicy even in the tenant's own namespace |
| **GCP ingress** | **working, verified by HTTP, 2026-11-02** (ADR-0021). `https://shopverse.platform.local/` and `https://argocd.platform.local/` both answer **200** through a Google global ALB, TLS terminated with a `platform-ca` certificate. **Same Gateway, same listeners, same routes as on-prem — two values differ**: the GatewayClass, and where the address comes from. The earlier 404s were URL-map propagation, which runs minutes behind the Gateway's own `Programmed` status |
| **`sectionName: https` earns its comment** | the http listener reports `attachedRoutes=0`, the https listener `attachedRoutes=2`. Without the pin a route attaches to EVERY compatible listener, including plain HTTP on port 80 — serving the application unencrypted on the same address with no error anywhere |
| **An orphaned disk, and the same bug as the load balancer** | `make gcp-down` destroyed the cluster cleanly and left `pvc-5f355018-…`, a 5 GB Persistent Disk, unattached and billing. `Destroy complete! Resources: 4 destroyed` was true and incomplete — Terraform never created the disk. **The PD CSI driver deletes it when the PVC goes, and destroying the cluster removes that driver first**, which is ADR-0021's ordering rule one object over, applied once instead of understood. The PVC comes from a StatefulSet `volumeClaimTemplate`, so Argo CD never created it and will not prune it. **Fixed:** `gcp-down` now deletes the tenant Applications, then the PVCs, then waits for the disks — and `cost-check` is the only thing that could have said so |
| **The check was the bug, three times** | `[fail] Gateway is Programmed=<absent>` on a working load balancer — this project's **first false negative**. Diagnosis 1 ("GKE writes `Ready`") was disproved by `Programmed=True` three minutes later; diagnosis 2 ("the address is the assertion") was disproved by the same run's own output, since GKE reserves the IP *first* and programs the data path after. The real cause: **no wait**, a transient state read once — second instance after the ESO store in backoff. And `[ ok ] 2 HTTPRoute(s) attached` counted **objects**, not `.status.listeners[].attachedRoutes`: third instance of counting what exists instead of asking whether it took effect |
| **`make gcp-smoke` now sends a packet** | it waits 300s for `Programmed`/`Ready`, reads the controller's own `attachedRoutes` and each route's `Accepted`/`ResolvedRefs` reasons, then **curls each hostname** through the address with the cluster CA (which it exports itself rather than telling you to run `make gcp-ca`). 2xx/3xx working, **404 routing, 5xx backend** — the first check in the cloud path that is not inference |
| **The address is an allocation** | On-prem `.200` is a *choice* written in nodes.json. On GKE the LB is **given** an address, a different one each session, and pinning it means reserving a static IP that GCP bills **while unattached** — so the address moves and the names follow it. `make gcp-address` |
| **The one ordering with money on it** | A GKE Gateway creates Google LB resources **Terraform never made and has no record of**. `make gcp-down` now deletes the ingress Application and waits for the forwarding rule to go **before** destroying the cluster — because destroying the cluster first removes the controller that would clean up. It proceeds anyway on timeout, in red, and `cost-check` lists them |
| **GCP session cost** | **~₹5/hour** now: ~₹3 for 2 spot nodes + 2 external IPs + 64 GB pd-standard, plus ~₹2 for the load balancer's forwarding rule |
| **GCP idempotency** | **established, 2026-11-01.** Two consecutive `make gcp-argocd` runs: `ok=24 changed=2`, then **`ok=22 changed=0`**. The gate every other module passed now holds on this substrate too |
| **Workload Identity** | **works.** The ServiceAccount carries the annotation and `ClusterSecretStore/vault-backend` is Ready — which settled three of ADR-0018's four unknowns at once, including the subtle one (Helm ignores an unknown values path silently, so "I set it" and "it took effect" needed a cluster to distinguish) |
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

**Delete the orphaned disk first — it is billing right now.** Nothing else in this repository is
costing money, and that one is:

```bash
gcloud compute disks delete pvc-5f355018-5202-48c0-bca3-0809b8e9aec8 \
  --zone=asia-south1-a --project=platform-eng-lab-261031
make cost-check          # should report nothing billable except the 1 Secret Manager version
```

**Module 08 is done.** Proven on a live cluster, not inferred: 8 Applications Synced/Healthy, all
8 tenant pods Running on `e2-standard-2`, MongoDB's volume Bound on a Persistent Disk, the six
keys delivered by External Secrets through Workload Identity, the namespace adopted by Argo CD,
and **`https://shopverse.platform.local/` and `https://argocd.platform.local/` both answering 200
through a Google ALB**. The 404s were URL-map propagation; the next run returned 200 with nothing
changed but the clock.

**What Module 08 cost in checks that were wrong rather than in things that were broken** — worth
reading before Module 09 repeats the shape against AWS:

| the check said | the truth was | the shape |
|:--|:--|:--|
| `Programmed=<absent>`, a failure | the Gateway was provisioning | a transient state read once, 2nd instance |
| `2 HTTPRoute(s) attached` | the objects existed; nothing served | counting what exists, 3rd instance |
| `Destroy complete! Resources: 4 destroyed` | a 5 GB disk was still billing | true and incomplete |

All three were green or clean while the thing was wrong, and in two of them **I diagnosed it wrong
before diagnosing it right** — twice over on the Gateway, committing the first wrong answer. The
fix that actually worked in every case was to stop reading objects and ask the system: curl the
load balancer, ask GCP for the disks.

### Next: on-prem, whenever those VMs are up

```bash
make onprem-argocd        # tenant-namespaces adopts shopverse-prod
make smoke                # now 8 checks - the 8th is the adoption
```

That closes the parking-lot entry about a namespace nothing in Git has managed for five modules.
`make smoke` fails loudly if the adoption has not happened, which is the point.

### What Module 08 leaves behind

- ~~**ShopVerse on GKE.**~~ **DONE 2026-11-02** — all 8 pods Running, the volume Bound, the six
  keys delivered. What it unblocked rather than finished is the NetworkPolicy proof: there is now
  a tenant to write a policy about, so **`make netpol-check` has a GCP counterpart to port** —
  `ADVANCED_DATAPATH` is still confirmed only by reading the control plane, and no packet has been
  blocked on this cluster. The one rule that cannot be written once for three substrates is "allow
  the ingress layer in", because the source is Cilium Envoy as `reserved:host` on-prem and a
  Google-owned range here.
- ~~**Ingress.**~~ **DONE, verified by HTTP** — ADR-0021 shipped a GKE Gateway rather than a
  `type=LoadBalancer` Service, which is what keeps ADR-0003 satisfied: the forwarding rule bills
  hourly while it exists, so `make gcp-down` deletes the Application and waits for the rules to go
  *before* destroying the cluster — and now does the same for the PVCs, after a disk survived a
  clean destroy. Both hostnames answer 200 with TLS from the cluster's own CA.
- **`make shopverse-check` has no GCP counterpart.** It hardcodes the on-prem `nodes.json` and the
  on-prem CA path, both of which now have GCP equivalents (`clusters/gcp/cluster.json`,
  `.cache/gcp-platform-ca.crt`), so porting it is a real task. It is also the only thing that would
  prove the storefront *serves* rather than merely answers — it registers a user, fills a cart,
  checks out, deletes MongoDB and confirms the order survived. **No longer blocked** — the Gateway
  returns 200, so every step of it has a working path. This is the next real piece of GCP work,
  alongside porting `make netpol-check`.
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

