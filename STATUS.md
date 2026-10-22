# Where we are

> **This file is the answer to "what was I doing?"** Update it at the end of every session,
> before you close the laptop. It takes thirty seconds and it is the reason this project will
> not stall like the last one.

**Last updated:** 2026-10-22
**Current module:** 01 — The on-prem substrate, built from code
**Overall progress:** 0 / 12 modules complete

---

## Right now

| | |
|:--|:--|
| **On-prem cluster** | not built — Module 01 code written, image not yet built |
| **GCP cluster** | not built |
| **AWS cluster** | not built |
| **Argo CD** | not installed |
| **ShopVerse running** | no |
| **Monthly spend** | ₹0 |

## The next action

1. ~~Push the scaffold~~ — done, three commits are on GitHub.
2. ~~Confirm C: is solid state~~ — done, Samsung NVMe confirmed.
3. Clone the repo **inside WSL** (`~/platform-engineering-lab`, not `/mnt/c`) — ADR-0005.
4. `make doctor` until it passes.
5. Create the AWS and GCP accounts with budget alarms **before** any resource exists (ADR-0003).

Then Module 01, which is already written and waiting:

```bash
cd packer/ubuntu-2404 && packer init . && packer build .   # ~20 min, once
cd ../.. && make onprem-vms                                # ~10 min, repeatable
```

Gate: destroy all three VMs, rebuild, and get identical nodes back. See
docs/runbooks/01-onprem-vms.md.

## Module 00 checklist

- [x] Repository structure defined
- [x] ADR-0001: three substrates, one platform definition
- [x] ADR-0002: GitOps ownership model (decided **before** anything is installed)
- [x] ADR-0003: cost guardrails for free-tier-only cloud
- [x] `.gitattributes` to kill the CRLF/BOM class of bugs permanently
- [x] Laptop specs captured → on-prem substrate chosen (ADR-0004)
- [x] Confirm C: is solid state — Samsung NVMe (238 GB); D: is a Seagate HDD
- [x] ADR-0005: WSL is the control workstation
- [ ] Repo cloned inside the WSL filesystem
- [ ] Install missing workstation tools until `make doctor` passes
- [ ] AWS account + budget alarm at $5
- [ ] GCP account + budget alert at ₹400
- [ ] `make doctor` passes on the workstation

## Session log

Keep this short. One line per session: what you did, what broke, what is next.

| Date | Module | What happened | Next |
|:--|:--|:--|:--|
| 2026-10-17 | 00 | Project restarted. Decisions and scaffold written before any cluster exists. | Capture laptop specs, create repo |
| 2026-10-22 | 01 | WSL confirmed available → ADR-0005: WSL becomes the control workstation, bash version of the VM script is now primary, PowerShell kept as fallback. GitHub App access granted, pushes work. | Build the image from WSL |
| 2026-10-22 | 01 | Module 01 written: Packer golden image (autoinstall, containerd, kubeadm held, sealed identity) plus a clone script that discovers the NAT subnet instead of editing VMware's DHCP config. Not yet run. | Build the image, run the create/destroy round trip |
| 2026-10-22 | 00 | Hardware captured: 32 GB, 12 threads, C: 106 GB SSD, D: 625 GB HDD. ADR-0004 fixes the substrate: 3 kubeadm VMs on the SSD, because etcd on a mechanical disk is a known failure mode. Repo created, scaffold ready to push. | Push scaffold, budget alarms, `make doctor` |
