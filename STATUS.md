# Where we are

> **This file is the answer to "what was I doing?"** Update it at the end of every session,
> before you close the laptop. It takes thirty seconds and it is the reason this project will
> not stall like the last one.

**Last updated:** 2026-10-27
**Current module:** 05 — The platform baseline (all components written; storage awaiting its first sync, then the gate)
**Overall progress:** Modules 00–04 complete — 5 / 13

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
| **Storage** | local-path-provisioner v0.0.37, default class `platform-local` (ADR-0015). **Awaiting `make onprem-up TAGS=argocd`** — the AppProject had to be opened to Rancher's repo first. Node-local: a dead node takes its data with it |
| **Certificates expire** | **2027-10-22** — `sudo kubeadm certs renew all` before then, or nothing works |
| **GCP cluster** | not built — account verified empty, ₹0 running |
| **AWS cluster** | not built |
| **Argo CD** | **running** — chart 10.11.0 / Argo CD v3.5.5, root app Synced, self-heal verified |
| **Platform components** | metrics-server 3.14.0, cert-manager v1.21.3 + internal PKI — both Synced/Healthy |
| **Internal CA** | `platform-ca` ClusterIssuer, Ready. Root valid to **2036-10-21**, key in `cert-manager/platform-ca-tls` |
| **ShopVerse running** | no |
| **Monthly spend** | ₹0 |

To bring the nodes back after a reboot or a `wsl --shutdown`:

```bash
make onprem-vms            # idempotent; recreates only what is missing
make onprem-vms-status
```

## The next action

**Module 05, two of four components done.** Both built to the ADR-0010 pattern, both Synced and
Healthy, nothing installed by hand.

| Component | Chart | What it proved |
|:--|:--|:--|
| metrics-server | 3.14.0 | the four-file pattern, and the per-environment overlay — `--kubelet-insecure-tls` is on-prem only |
| cert-manager | v1.21.3 | sync waves, a wrapper chart carrying its own templates, and the PKI from ADR-0011 |
| Cilium kube-proxy replacement | 1.20.3 | that a ConfigMap is a request and `cilium-dbg status` is the answer — see the postscript on ADR-0012 |

Remaining in this module:

1. ~~**A Gateway (ingress via Gateway API).**~~ **Done 2026-10-27.** CRDs pinned by digest,
   `gatewayAPI` and the kube-proxy replacement it forced (ADR-0012), a Cilium address pool and
   L2 announcement policy (ADR-0013), the Gateway, and its certificate from `platform-ca`.
   `make smoke` is 7/7 and `https://gw.platform.local` returns 404 over TLS our own CA signed,
   which is the whole chain working with nothing to route to yet.

2. **A storage class.** Nothing has needed persistence yet; ShopVerse will in Module 06.
3. **The module gate:** the whole app-of-apps Synced and Healthy, and the overlay mechanism
   proven by a value that genuinely differs per environment — which the cert-manager
   `platformPKI.enabled` boolean already does.

Then two follow-ups this module opened and should close (`docs/parking-lot.md`): the kubelet
serving certificates and the metrics-server APIService both skip TLS verification, and
cert-manager existing makes both fixable. They get fixed **together** — one alone leaves an
unverified hop either side of a verified one.

Useful commands added this session:

```bash
make gitops-status        # every Application: sync, health, revision
make gitops-check-pins    # is any chart pin behind what the repo offers?
make gitops-render CHART=cert-manager   # exactly what Argo CD will apply
make gitops-drift         # anything running that no Application claims
make lint                 # everything checkable without a cluster
```

Before any cloud module: AWS and GCP budget alarms (ADR-0003) — still outstanding.

Runbooks: `01-onprem-vms.md` · `cluster-bootstrap.md` · `03-ansible.md` · `04-argocd.md`

## Module 00 checklist

- [x] Repository structure defined
- [x] ADR-0001: three substrates, one platform definition
- [x] ADR-0002: GitOps ownership model (decided **before** anything is installed)
- [x] ADR-0003: cost guardrails for free-tier-only cloud
- [x] `.gitattributes` to kill the CRLF/BOM class of bugs permanently
- [x] Laptop specs captured → on-prem substrate chosen (ADR-0004)
- [x] Confirm C: is solid state — Samsung NVMe (238 GB); D: is a Seagate HDD
- [x] ADR-0005: WSL is the control workstation
- [x] Repo cloned inside the WSL filesystem
- [x] Install workstation tools — `make tools` installed packer, ansible, argocd, yq, jq, aws
- [ ] AWS account + budget alarm at $5
- [ ] GCP account + budget alert at ₹400
- [x] `make doctor` passes — 20 ok, 0 warnings, 0 failures
- [x] ADR-0006: libvirt/KVM replaces VMware — Terraform owns Layer 0 properly
- [x] `.wslconfig` memory raised

## Module 01 checklist

- [x] Packer golden image from Ubuntu's official cloud image — 3 min, 2.8 GB, sealed
- [x] Terraform owns the network, the volumes, the seeds and the domains
- [x] Provider pinned exactly (0.9.9) and the config written against the dumped schema
- [x] Every node reachable on its declared address
- [x] Three distinct machine-ids — the seal works
- [x] **The gate: `make onprem-vms-destroy` then `make onprem-vms`, clean**
- [x] Serial console on every domain — interactive **and** recorded to a file

## Module 02 checklist

- [x] kubeadm config as a FILE in Git, not flags — `clusters/onprem/kubeadm/init.yaml`
- [x] `kubernetesVersion` pinned to the held packages (v1.34.12)
- [x] `resolvConf` set, so CoreDNS never hit the systemd-resolved stub loop
- [x] Control plane initialised; the pre-CNI `NotReady` state observed deliberately
- [x] ADR-0007: Cilium, with kube-proxy kept until Module 04 removes it
- [x] Cilium 1.20.3 installed from a values file in Git
- [x] Both workers joined, labelled, `cluster-pool` IPAM giving each node its own /24
- [x] `make smoke` passes — now across every ordered pod pair, not just one
- [x] A worker reboot rejoins unaided — and did it faster than the 40s grace period, so the
      control plane never saw it leave. Node failure handling is therefore still untested;
      the `virsh destroy` experiment in the runbook is how to test it properly.
- [x] `cilium connectivity test` passes — 81/82 first run; `check-log-errors` green after a
      counter reset, which confirmed the restarts were node reboots (`LASTSTATE: Unknown`)
- [x] Notes added to the runbook where reality differed from what was written

## Module 03 checklist

- [x] ADR-0008: Packer owns machine configuration, Ansible asserts it
- [x] Inventory generated from `nodes.json` — cannot describe a cluster that does not exist
- [x] `preflight` asserts nine things about the image and changes nothing
- [x] kubeadm config is a template rendered from the inventory, not a second copy of the CIDRs
- [x] Cilium installed from the values file already in Git
- [x] Idempotency gated on one file per role, not on `--force`
- [x] **The gate: destroy the VMs, rebuild, `make onprem-up`, `make smoke` — zero manual steps**
- [x] **The second run reports `changed=0` on all three hosts**

## Module 04 checklist

- [x] ADR-0009: the seam is three objects, the layout, repo access, annotation tracking
- [x] Ansible role for Argo CD, pinned chart, re-runnable when Argo CD is the broken thing
- [x] Two `AppProject`s — `platform` trusted, `tenants` unable to create cluster-scoped objects
- [x] Root `Application`, non-recursive, no finalizer
- [x] A canary `Application` whose only job is to answer "is GitOps working right now?"
- [x] `make gitops-drift` — finds anything running that nothing in Git claims
- [x] Run it — chart 10.11.0 carries Argo CD v3.5.5, which matches the argocd CLI's minor
- [x] Gate part 1: a commit changed the cluster with no `kubectl` (revision b4fe706)
- [x] Gate part 2: both a field patch and a full delete were reverted by self-heal
- [x] `make gitops-drift` clean — nothing running that no Application claims

## Session log

Keep this short. One line per session: what you did, what broke, what is next.

| Date | Module | What happened | Next |
|:--|:--|:--|:--|
| 2026-10-24 | 05 | ADR-0010 fixed the wrapper chart shape at four files; ADR-0011 decided the trust model — self-signed root on-prem, ACME in both clouds, one boolean apart. metrics-server and cert-manager both deployed by Argo CD, PKI Ready, root CA valid to 2036. Three chart pins were guessed wrong from memory (one version did not exist), so `make gitops-check-pins` now makes the repo answer that question — and caught cert-manager two minors behind on its first run. Two tooling bugs of mine found by using the tools: `make lint` reported failures on correct Go templates, and `make gitops-render` showed the wrong namespace, which is worse than showing nothing because it gets believed. | Gateway API, then a storage class |
| 2026-10-24 | 04 | **Module 04 closed.** Argo CD installed by Ansible, root Application Synced, and both halves of the gate pass: a commit changed the cluster with no kubectl, and self-heal reverted both a field patch and a full delete. `make gitops-drift` finds nothing unclaimed. The laptop restarted mid-module and everything came back untouched — `make onprem-vms` then `make onprem-up`, with kubeadm, Cilium and Argo CD all reporting "already done". Fixed along the way: the playbook now waits for the nodes instead of assuming they are up, and `make lint` exists because I verified a change with `--syntax-check \| tail -2` and a pipe discards the exit code. | Module 05 — the platform baseline |
| 2026-10-23 | 03 | **Module 03 closed.** Cluster rebuilt from destroyed nodes in about four minutes with no manual steps, and the second run reports changed=0. Three bugs found, each only findable by a different test: running twice on a live cluster caught a task that renamed the file `fetch` uses as its idempotency marker (so `fetch` re-downloaded forever); the destroy-and-rebuild caught `template` not creating `/etc/kubernetes/kubeadm`, which existed only because Module 02 made it by hand; and `--syntax-check` caught paths in `ansible.cfg` resolving against the config file rather than the shell. Idempotency proves the gates work; only a rebuild proves the roles are complete. | Module 04 — Argo CD |
| 2026-10-23 | 02 | **Module 02 closed.** Gate green: `make smoke`, a worker reboot rejoining unaided, and `cilium connectivity test`. Three lessons kept: `kubeadm config validate` says `ok` to a truncated file, so configuration moved into Git behind a script that checksums the copy and counts the documents; `make smoke` was testing one pod pair and reporting it as "pod-to-pod across nodes", so it now tests all six and keeps the namespace on failure; and the reboot test never saw `NotReady` because the VM came back inside the 40s grace period, which is documented along with the real six-minute eviction timeline. | Module 03 — Ansible |
| 2026-10-23 | 02 | Cluster up: three nodes Ready on v1.34.12, Cilium 1.20.3, `make smoke` passing. Two things went wrong and both were worth it — a heredoc paste of the kubeadm config truncated silently while `kubeadm config validate` said `ok` (configuration now lives in Git and is copied by a script that checksums it and counts the documents), and `helm` could not resolve `k8s-cp01.platform.local` because cloud-init writes `/etc/hosts` on the nodes and never on the workstation (`make hosts`, plus `generateHosts=false` so WSL stops undoing it). Also found that `make smoke` only ever tested one pod pair, missing the worker-to-worker tunnel entirely. | Reboot test, connectivity test, then Module 03 |
| 2026-10-22 | 01 | Serial console added to every domain — interactive on loopback and recorded to a file. It paid for itself immediately: the first boot log proved the qcow2 fix (`vda: vda1 vda14 vda15 vda16` — a partition table, where before QEMU saw none) and revealed that a Terraform "update in-place" on a domain silently **reboots** it. That is harmless now and would take etcd down from Module 02, so it is written up in the runbook. Image now disables ufw and boots to multi-user. | Module 02 step 0 |
| 2026-10-22 | 01 | **Module 01 done.** Nodes were created but unreachable: domains running, CPU time flat at 5.8s, no lease, no SSH. The QEMU command line showed `"driver":"raw"` — `devices.disks[].driver` had been omitted, libvirt defaults to raw, and QEMU read the qcow2 header as a partition table. Adding `driver = { name = "qemu", type = "qcow2" }` fixed it; destroy/apply round trip now passes in 28s. | Module 02: kubeadm by hand |
| 2026-10-17 | 00 | Project restarted. Decisions and scaffold written before any cluster exists. | Capture laptop specs, create repo |
| 2026-10-22 | 01 | Sagar asked why VMware rather than QEMU. KVM confirmed working in WSL2, so the substrate switched to libvirt — the deciding argument being that Terraform can own Layer 0 for real, with cloud-init matching how the cloud modules will work. Module 01 rewritten: Packer qemu builder from Ubuntu's cloud image, Terraform libvirt stack. Not yet run. | Raise WSL memory, make tools, make image |
| 2026-10-22 | 01 | Toolchain installed, `make doctor` clean (16/0/0). Found that Packer cannot run in WSL — the vmware-iso builder executes local VMware binaries — so `make image` now syncs to C:\VMs\build and runs packer.exe through interop. ADR-0005 updated. | Install packer.exe on Windows, build the image |
| 2026-10-22 | 01 | WSL confirmed available → ADR-0005: WSL becomes the control workstation, bash version of the VM script is now primary, PowerShell kept as fallback. GitHub App access granted, pushes work. | Build the image from WSL |
| 2026-10-22 | 01 | Module 01 written: Packer golden image (autoinstall, containerd, kubeadm held, sealed identity) plus a clone script that discovers the NAT subnet instead of editing VMware's DHCP config. Not yet run. | Build the image, run the create/destroy round trip |
| 2026-10-22 | 00 | Hardware captured: 32 GB, 12 threads, C: 106 GB SSD, D: 625 GB HDD. ADR-0004 fixes the substrate: 3 kubeadm VMs on the SSD, because etcd on a mechanical disk is a known failure mode. Repo created, scaffold ready to push. | Push scaffold, budget alarms, `make doctor` |

## Verified on 2026-10-27

- `make smoke` **6 of 6**, including the new step 6: NodePort answered on all three nodes from
  the workstation, with the two forwarded hops (no local backend) marked as such.
- `make onprem-up` **changed=0** on all three nodes — the Module 03 gate still holds with the
  CNI, the Gateway API CRDs and the kube-proxy removal all in the playbook.
- `make hosts` reconciles stale SSH host keys after a VM rebuild, so the man-in-the-middle
  warning means something again.

## Open, not yet understood

**The Argo CD seam applied itself once without a reason.** On 2026-10-26 the
`argocd : Apply the seam` task reported `changed` for `root-onprem.yaml` with nothing in Git
having touched that file. It has not reproduced — the next two runs skipped the apply with both
diffs returning 0. The `kubectl diff --server-side` gate in front of it is supposed to make
that impossible, so either the gate has a hole or the live object genuinely differed for a
moment. Harmless when it happens (the apply is a no-op), but it makes `changed=0` less
trustworthy than it looks. **Watch for it; do not invent a mechanism.**
