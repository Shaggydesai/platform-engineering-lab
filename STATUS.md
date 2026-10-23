# Where we are

> **This file is the answer to "what was I doing?"** Update it at the end of every session,
> before you close the laptop. It takes thirty seconds and it is the reason this project will
> not stall like the last one.

**Last updated:** 2026-10-23
**Current module:** 04 — Argo CD and the first reconciliation (written, not yet run)
**Overall progress:** Modules 00–03 complete — 4 / 13

---

## Right now

| | |
|:--|:--|
| **On-prem nodes** | **built and verified** — k8s-cp01 .10, k8s-w01 .11, k8s-w02 .12, destroy/apply round trip passes |
| **On-prem cluster** | **running, and rebuildable from nothing in ~4 minutes** — 3 nodes, v1.34.12, Cilium 1.20.3 |
| **Certificates expire** | **2027-10-22** — `sudo kubeadm certs renew all` before then, or nothing works |
| **GCP cluster** | not built — account verified empty, ₹0 running |
| **AWS cluster** | not built |
| **Argo CD** | not installed |
| **ShopVerse running** | no |
| **Monthly spend** | ₹0 |

To bring the nodes back after a reboot or a `wsl --shutdown`:

```bash
make onprem-vms            # idempotent; recreates only what is missing
make onprem-vms-status
```

## The next action

Module 04 is written and validated but **not yet run**. The decisions are recorded in ADR-0009;
the code is the Ansible `argocd` role plus three files in `gitops/bootstrap/`.

```bash
git pull
helm search repo argo/argo-cd --versions | head -3   # confirm 10.8.3 is still current
make onprem-argocd                                   # just this role
make gitops-status
```

Then the two-part gate:

1. **A commit changes the cluster** — bump `generation` in
   `gitops/manifests/gitops-canary/configmap.yaml`, push, and read the ConfigMap back.
2. **`kubectl delete` is reverted** — delete that ConfigMap and watch self-heal restore it.
   This is the half that matters: sync proves Argo CD *can* apply Git, self-heal proves Git is
   **in charge**.

Then `make gitops-drift`, which is ADR-0002 Rule 1 turned into a query rather than a promise.

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
- [ ] **Run it**
- [ ] Gate part 1: a commit changes the cluster with no `kubectl`
- [ ] Gate part 2: `kubectl delete` on a managed resource is reverted by self-heal

## Session log

Keep this short. One line per session: what you did, what broke, what is next.

| Date | Module | What happened | Next |
|:--|:--|:--|:--|
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
