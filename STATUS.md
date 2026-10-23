# Where we are

> **This file is the answer to "what was I doing?"** Update it at the end of every session,
> before you close the laptop. It takes thirty seconds and it is the reason this project will
> not stall like the last one.

**Last updated:** 2026-10-23
**Current module:** 03 — Ansible: the bootstrap layer
**Overall progress:** Modules 00, 01 and 02 complete — 3 / 13

---

## Right now

| | |
|:--|:--|
| **On-prem nodes** | **built and verified** — k8s-cp01 .10, k8s-w01 .11, k8s-w02 .12, destroy/apply round trip passes |
| **On-prem cluster** | **running** — 3 nodes Ready, v1.34.12, Cilium 1.20.3, `make smoke` passes |
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

Module 01 is closed: the gate (`onprem-vms-destroy` then `onprem-vms`) passed with three
reachable nodes and three distinct machine-ids.

**Module 02 is closed.** `make smoke` passes on three nodes, a worker reboot rejoins unaided, and
`cilium connectivity test` is green — 81 of 82 tests first time, and the one failure was
`check-log-errors` objecting to restart counts caused by our own node reboots, which passed once
the counters were reset.

**Module 03 — Ansible: the bootstrap layer.** Everything done by hand in Module 02 becomes code.
The gate, from the roadmap: `terraform destroy` the VMs, run `make onprem-up`, get a working
cluster with **zero** manual steps — and running it twice reports no changes the second time.

**The roles are written and syntax-checked; they have not been run.** Next:

```bash
make onprem-ping           # can Ansible reach all three?
make onprem-preflight      # assert the image. Changes nothing, fails loudly.
make onprem-up             # against the EXISTING cluster first - should be nearly all 'ok'
```

Running it against the cluster that already exists is the cheapest possible test of the gating
logic: if `control_plane` or `workers` tries to re-initialise or re-join, the gate is wrong and
nothing has been lost. Only then destroy and rebuild.

Decided along the way — **ADR-0008: Packer owns machine configuration, Ansible asserts it.** The
golden image already does swap, modules, sysctls, containerd and the packages; defining any of
that twice would leave it with no owner (ADR-0002 Rule 4). So `preflight` checks and never
changes, which also makes every `onprem-up` a regression test on the image.

Runbook: `docs/runbooks/03-ansible.md`

Before any cloud module: AWS and GCP budget alarms (ADR-0003) — still outstanding.

Runbooks: `docs/runbooks/01-onprem-vms.md` (nodes) · `docs/runbooks/cluster-bootstrap.md` (cluster)

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

## Session log

Keep this short. One line per session: what you did, what broke, what is next.

| Date | Module | What happened | Next |
|:--|:--|:--|:--|
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
