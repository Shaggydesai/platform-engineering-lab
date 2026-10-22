# Where we are

> **This file is the answer to "what was I doing?"** Update it at the end of every session,
> before you close the laptop. It takes thirty seconds and it is the reason this project will
> not stall like the last one.

**Last updated:** 2026-10-22
**Current module:** 01 — The on-prem substrate, built from code
**Overall progress:** Module 00 complete, 01 in progress — 1 / 13

---

## Right now

| | |
|:--|:--|
| **On-prem cluster** | not built — Module 01 rewritten on libvirt (ADR-0006), image not yet built |
| **GCP cluster** | not built — account verified empty, ₹0 running |
| **AWS cluster** | not built |
| **Argo CD** | not installed |
| **ShopVerse running** | no |
| **Monthly spend** | ₹0 |

## The next action

Module 00 complete. GCP verified empty. Substrate switched to KVM/libvirt (ADR-0006).

1. `.wslconfig` — raise WSL memory to 26GB, then `wsl --shutdown` (nodes need 20GB, WSL caps at 15)
2. `make tools` then `exec su - $USER` (libvirt group needs a new login shell)
3. `make doctor` — now checks /dev/kvm, libvirtd, the storage pool and memory headroom
4. `make image` (~3 min) then `make onprem-vms` (~2 min)
5. The gate: `make onprem-vms-destroy && make onprem-vms`
6. Before any cloud module: AWS and GCP budget alarms (ADR-0003)

Runbook: docs/runbooks/01-onprem-vms.md

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
- [x] `make doctor` passes — 16 ok, 0 warnings, 0 failures
- [x] ADR-0006: libvirt/KVM replaces VMware — Terraform owns Layer 0 properly
- [ ] `.wslconfig` memory raised to 26GB

## Session log

Keep this short. One line per session: what you did, what broke, what is next.

| Date | Module | What happened | Next |
|:--|:--|:--|:--|
| 2026-10-17 | 00 | Project restarted. Decisions and scaffold written before any cluster exists. | Capture laptop specs, create repo |
| 2026-10-22 | 01 | Sagar asked why VMware rather than QEMU. KVM confirmed working in WSL2, so the substrate switched to libvirt — the deciding argument being that Terraform can own Layer 0 for real, with cloud-init matching how the cloud modules will work. Module 01 rewritten: Packer qemu builder from Ubuntu's cloud image, Terraform libvirt stack. Not yet run. | Raise WSL memory, make tools, make image |
| 2026-10-22 | 01 | Toolchain installed, `make doctor` clean (16/0/0). Found that Packer cannot run in WSL — the vmware-iso builder executes local VMware binaries — so `make image` now syncs to C:\VMs\build and runs packer.exe through interop. ADR-0005 updated. | Install packer.exe on Windows, build the image |
| 2026-10-22 | 01 | WSL confirmed available → ADR-0005: WSL becomes the control workstation, bash version of the VM script is now primary, PowerShell kept as fallback. GitHub App access granted, pushes work. | Build the image from WSL |
| 2026-10-22 | 01 | Module 01 written: Packer golden image (autoinstall, containerd, kubeadm held, sealed identity) plus a clone script that discovers the NAT subnet instead of editing VMware's DHCP config. Not yet run. | Build the image, run the create/destroy round trip |
| 2026-10-22 | 00 | Hardware captured: 32 GB, 12 threads, C: 106 GB SSD, D: 625 GB HDD. ADR-0004 fixes the substrate: 3 kubeadm VMs on the SSD, because etcd on a mechanical disk is a known failure mode. Repo created, scaffold ready to push. | Push scaffold, budget alarms, `make doctor` |
