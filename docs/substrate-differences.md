# Where the three substrates actually differ

> **This is Module 09's "done when".** The roadmap asks for *"the six concrete differences from
> the GCP environment, explained in writing"*, along the axes ADR-0001 chose before any of it was
> built. This file is that, written after all three substrates had run, so each row says what
> **happened** rather than what was expected.
>
> **Last verified:** 2026-11-05, against on-prem (running), `gcp-platform` (built and destroyed in
> Module 08) and `aws-platform` (built and destroyed in Module 09).

Every row carries a status, and three of them are **not** "verified":

| | meaning |
|:--|:--|
| **verified** | built on all three substrates and observed |
| **partly** | built on some, and the gap is named below rather than implied |
| **not yet** | never exercised on at least one substrate. The difference is real; the evidence is not here |

A note on why that matters: the easiest way to write this document would have been to fill in six
rows from the documentation of three products. Four of the rows below would have been wrong.

---

## The six axes ADR-0001 chose

### 1. Control plane — **verified**

|  | on-prem | GCP | AWS |
|:--|:--|:--|:--|
| who runs it | we do | Google | we do |
| Kubernetes | **v1.34.12** | **v1.36.4** | **v1.34.12** |
| pinned by | the Packer image + `preflight` | nothing, and it cannot be | cloud-init + `preflight` |

**The concrete finding is that the three substrates do not run the same Kubernetes, and only one
pair does.** On-prem and AWS agree exactly, to the patch, because both install
`kubernetes.package_version` (`1.34.12-1.1`) from the same four scripts and `preflight` refuses to
continue if the installed `kubeadm` disagrees with `clusters/*/kubernetes.version`.

GKE was two minors ahead and will move again on Google's schedule: `release_channel = REGULAR`
upgrades the control plane and `auto_upgrade = true` upgrades the nodes. That is not a defect to
fix — it is what "managed" means — but it means **the platform's portability claim is bounded by
whatever the newest GKE will accept**. The thing to watch for is a chart with a minimum Kubernetes
version: it will work on GKE and fail on the two self-managed clusters, which is the opposite of
the direction anyone expects.

**What it cost to learn:** nothing on GKE, and a real bug on the other two. Pinning the apt
*repository* to a minor while running `apt-get install kubelet kubeadm kubectl` with no version
installs "newest in the repo today". The laptop's image was baked when v1.34.12 was current and had
been silently correct ever since; AWS ran the same scripts on 2026-11-05 and got **v1.34.13**.
`preflight` caught it. The same definition, the same repository, a different day, a different
Kubernetes — found only because the scripts were finally delivered a second way.

---

### 2. LoadBalancer Services — **not yet**

|  | on-prem | GCP | AWS |
|:--|:--|:--|:--|
| mechanism | Cilium L2 announcements over ARP | GKE Gateway → Google global ALB | **nothing** |
| address | `192.168.100.200–.239` pool | `34.36.43.255`, Google-allocated | — |
| failover | **measured ~15s**, bounded by the L2 lease | Google's, unmeasured | — |
| billed | no | 2 forwarding rules, while it exists | — |

On-prem and GCP both work and have been exercised end to end: 200 from both hostnames through the
GKE Gateway in Module 08, and a measured 15-second ingress failover on a hard node power-off
on-prem.

**AWS has no ingress at all, and `l2announcements: true` is still set there, where it cannot
work.** AWS's fabric does not honour gratuitous ARP for an address it has not itself assigned to an
ENI, so the announcement is simply not heard. It does not stop the CNI starting and nothing on that
substrate requests a `LoadBalancer` yet, so it is **recorded as a difference rather than fixed as a
bug** — the honest reason being that choosing the AWS answer is a real decision and it was not
going to be made well with a cluster billing by the hour.

The three candidates, for whoever picks this up:

- **An NLB created by a controller in the cluster.** Closest to the GCP story, and the only one
  that gives a real external address. It bills, and ADR-0021's ordering rule applies: it must be
  destroyed *before* the Terraform state that owns the VPC, because the controller that would
  remove it dies with the cluster.
- **NodePort plus the node's public address.** Free, and closest to the on-prem behaviour in
  spirit. No cloud load balancer to orphan.
- **Nothing**, with Gateway API exercised only on-prem and GKE.

Until that is settled, **a Gateway on AWS will sit `<pending>` forever and the cause will look like
the CNI.**

---

### 3. Storage class — **not yet**

|  | on-prem | GCP | AWS |
|:--|:--|:--|:--|
| provisioner | local-path-provisioner v0.0.37 | `pd-balanced` CSI | **none installed** |
| default class | `platform-local` | GKE's | — |
| a dead node | **takes its data with it** | the disk survives, reattaches | — |

On-prem is deliberately node-local, and that limitation is the point: ADR-0015 chose it knowing a
dead node loses its volume, because the alternative (Longhorn) is a distributed storage system to
operate on three laptop VMs.

GCP's difference is not the driver, it is **who owns the disk**. A StatefulSet's PVC comes from a
`volumeClaimTemplate`, so **Argo CD never created it and will not prune it** — which is correct
everywhere except on a cluster about to be destroyed. `make gcp-down` left a 5 GB unattached
Persistent Disk billing after reporting `Destroy complete! Resources: 4 destroyed`. That message
was true and incomplete: the disk was never in Terraform's state, and the CSI driver that would
have deleted it was removed with the cluster.

**AWS has no CSI driver and nothing has requested a volume there.** The EBS CSI driver also needs
IRSA, which is gap 5 below — so this row and that one are the same piece of missing work.

---

### 4. Node lifecycle — **verified, and this is the one AWS taught**

|  | on-prem | GCP | AWS |
|:--|:--|:--|:--|
| who ends a node's life | we do, deliberately | Google's auto-upgrade | **AWS, without warning** |
| observed | power-off tests | not observed | **all three reclaimed mid-session** |

On 2026-11-05, between one playbook run and the next, **AWS reclaimed all three spot instances.**
The symptom was three simultaneous SSH timeouts; the diagnosis came from `terraform plan`:

```
Plan: 3 to add, 0 to change, 0 to destroy.
```

**That `0 to destroy` is the design working.** `instance_market_options` sets
`instance_interruption_behavior = "terminate"` rather than `stop` or `hibernate`, and the root
volume sets `delete_on_termination = true` — so AWS took the disks with the instances and there was
nothing orphaned to find. A *stopped* spot instance keeps its EBS volume, which keeps billing, which
is exactly the orphan found on GCP one module earlier. The decision was made on paper in ADR-0021's
shadow and was then tested for real, by AWS, for free.

What it also exposed: **a reclaimed instance comes back at a new public address**, and
`~/.kube/config` does not. And the rebuilt nodes answer SSH about ninety seconds before they are
usable, because on a cloud substrate the image scripts run from cloud-init at first boot rather
than at image-build time. Both now have mechanisms rather than instructions — see the unpredicted
differences below.

**The honest asymmetry:** this cluster has no answer for losing the *control plane* to an
interruption. One node, no etcd quorum anywhere else; the session simply ends. Module 11 makes that
the subject rather than the accident.

---

### 5. Identity — **partly**

|  | on-prem | GCP | AWS |
|:--|:--|:--|:--|
| **human** credential | static, on the laptop | `gcloud` ADC, **no key file** | `aws login`, **12-hour, no access key** |
| **workload** identity | n/a | Workload Identity, in use | **nothing — no instance profile** |

The human half is **verified and is better than ADR-0001 predicted on both clouds.** Neither cloud
has a long-lived credential anywhere: GCP uses Application Default Credentials and AWS uses
`aws login`, which issues browser-obtained credentials valid for twelve hours. **No service-account
key file and no AWS access key exists on this laptop or in this repository.** A root access key was
created once, was caught by `make aws-guardrails` refusing to run, and was deleted.

That refusal is also where the AWS identity design was found to be wrong. ADR-0023 designed an IAM
user plus an MFA-gated admin role, bootstrapped from CloudShell — a day of careful work against
documentation for **a different product.** AWS uses one name, "sign up for AWS", for two things
with different identity models: on the free account plan there is no root user (an AWS Builder ID
instead), IAM users are programmatic-access only, and IAM Identity Center, Organizations and
CloudShell are all unavailable. One click on "IAM" in the console in the first hour would have
caught it. ADR-0024 supersedes it with the scheme above, which is both simpler and closer to GCP's.

**The workload half does not exist on AWS.** The instances have **no `iam_instance_profile` at
all** — `terraform/aws/main.tf` sets none — so there is no IRSA, no instance-profile identity, and
nothing in the cluster can call an AWS API. That is why there is no EBS CSI driver (axis 3) and no
load-balancer controller (axis 2): all three are the same missing piece, and it is the obvious next
thing to build on that substrate.

On-prem's "static credentials" row deserves naming too, because it is the sharpest version of the
problem: `.cache/vault-init.json` holds the **only** copy of Vault's five unseal keys and root
token, and `/etc/kubernetes/enc/key1.b64` on the control-plane node is a second irreducible secret
(the etcd encryption key), deliberately never copied to the workstation. Losing either is
unrecoverable. A cloud KMS removes that class of problem; the laptop cannot.

---

### 6. Cost of a mistake — **verified, with numbers**

|  | on-prem | GCP | AWS |
|:--|:--|:--|:--|
| a forgotten cluster costs | electricity | credits | **a card** |
| measured rate | — | ₹0 steady state, credits for the rest | **~$0.106/hr ≈ ₹9.4/hr** |
| alarm | n/a | ₹400 budget | $5 budget, thresholds 50/90/100% |
| **does the alarm stop anything?** | n/a | **no** | **no, and there is no spend cap available** |

The AWS number is measured rather than estimated: 3 × `m6a.large` spot at ~$0.0266/hr, 3 × 30 GB
gp3 at ~$0.0036/node, 3 × public IPv4 at $0.005. Module 09's working session ran about 3.3 hours.

**The difference that matters is not the rate, it is the absence of a backstop.** ADR-0003
Decision 6 put Module 09 on an uncredited AWS account deliberately, and on the free account plan
there is no spend cap at all — the limit that actually pauses resources exists only after upgrading
to a paid plan. A budget **alerts**; it does not stop anything. So on AWS the real control is
`make aws-down`, and the budget is only the thing that tells you it was forgotten.

Which is why the one command this project will not skip is the pair at the end of every cloud
session (ADR-0003 Decision 5):

```
make aws-down && make cost-check
```

`cost-check` sweeps **every enabled region**, not a list anybody wrote down — a lesson that cost
three findings to learn, the sharpest being that this account's console opens in `eu-north-1`
(AWS's default, not a choice) while the sweep covered `ap-south-1` and `us-east-1`.

---

## Four differences ADR-0001 did not predict

These are the ones worth more than the six above, because they were not visible until the same code
ran on two substrates.

### A. The kubeconfig a cluster hands you names an address you cannot reach

kubeadm writes `controlPlaneEndpoint` into `admin.conf`. On AWS that is the control plane's
**private** address by deliberate choice — workers join through it, and over a public IP every
kubelet-to-API-server packet would leave through the internet gateway and be billed. On-prem one
address serves both, so the fetched file works unchanged and **nothing in the repository had ever
needed to distinguish the two.**

Four roles and one playbook ran `kubectl` on the workstation with `KUBECONFIG` set to that file.
Each failed with `dial tcp 10.20.1.10:6443: i/o timeout` — a network error, from a working cluster,
hundreds of lines into a playbook. It was fixed four separate times in one afternoon because each
fix was applied to the files in front of me rather than to the rule.

**Now:** the `control_plane` role writes one reachable copy, and `make lint` enforces that
`kubeconfig_fetch_path` is *used* only inside that role.

### B. The image scripts run at a different time, not just in a different place

ADR-0025 says the same four scripts build the node on every substrate. True — and on-prem Packer
runs them at **image-build** time while AWS cloud-init runs them at **first boot**. That single
difference produced two bugs: the version-pin bug in axis 1, and a race where a rebuilt instance
answers SSH ninety seconds before `br_netfilter` is loaded, so `preflight` fails an assertion on a
node that is about to pass it.

`make aws-wait` already existed for the second one and did not help, because it depends on somebody
remembering it. **Now** the playbook waits for `/var/lib/cloud/image-ready` itself, per host, and
prints `cloud-init status --long` plus the build log when it times out.

### C. On EC2, an identity is *allocated* unless you declare it

EC2 names a host after its address (`ip-10-20-1-10`), and **kubeadm registers a node under its
hostname** — so `kubectl get nodes` would have shown `ip-10-20-1-10`, permanently, instead of
`aws-cp01`. The private addresses had to be declared in `clusters/aws/cluster.json` too, because
otherwise Terraform cannot know them when it renders the user-data, so nothing can write
`/etc/hosts`, and `preflight` requires every node to resolve every other by name.

On-prem all of this is free: the libvirt seed sets it, because on-prem every address was always a
choice. The cloud equivalent of "a choice" is "a thing you must say out loud".

### D. Removing kube-proxy makes one CNI value substrate-specific

`cilium-values.yaml` set `k8sServiceHost: k8s-cp01.platform.local` — a name that exists only in the
libvirt nodes' `/etc/hosts`. With `kubeProxyReplacement: true` there is **no `kubernetes.default`
ClusterIP to fall back to**, because kube-proxy is gone and Cilium is the thing that would have
programmed that address. So on EC2 the agent could not reach the API server at all, and the only
symptom was a DaemonSet that never became available.

The file's own comment had predicted this in Module 04 — *"THIS IS NOW LOAD-BEARING"* — without
noticing the value was a hostname only one substrate has.

**Now:** one values file still, plus `cilium_values_override` from the inventory, merged into the
parsed structure and written out — so the role's idempotency check still compares what helm holds
against what the role passed. `--set` would have broken that check and reinstalled the CNI on every
run.

---

## What is the same, and that is the result

| | |
|:--|:--|
| playbook | `ansible/playbooks/cluster.yml`, unforked |
| roles | `preflight`, `control_plane`, `etcd_encryption`, `gateway_api`, `cilium`, `kube_proxy_removal`, `workers`, `argocd` — all eight, on-prem and AWS |
| Kubernetes | v1.34.12 on both self-managed substrates, to the patch |
| CNI | Cilium 1.20.3, `kubeProxyReplacement: true`, 0 `KUBE-SVC` iptables rules |
| Gateway API | CRDs v1.6.3, pinned by digest `356c2b8e…` |
| Argo CD | chart 10.11.0 → v3.5.5, same role, all three substrates |
| what differs | one inventory per substrate, and one CNI value |

Three bare Ubuntu instances to Argo CD `Synced/Healthy` in a single run, `failed=0`. The
differences above are the interesting part; that list is the reason they are legible as
differences at all.
