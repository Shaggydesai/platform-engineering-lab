# Where we are

> **This file is the answer to "what was I doing?"** Update it at the end of every session,
> before you close the laptop. It takes thirty seconds and it is the reason this project will
> not stall like the last one.

**Last updated:** 2026-10-22
**Current module:** 00 — Foundations (repository, decisions, guardrails)
**Overall progress:** 0 / 12 modules complete

---

## Right now

| | |
|:--|:--|
| **On-prem cluster** | not built — substrate decided (3 VMs, kubeadm, on C:) — see ADR-0004 |
| **GCP cluster** | not built |
| **AWS cluster** | not built |
| **Argo CD** | not installed |
| **ShopVerse running** | no |
| **Monthly spend** | ₹0 |

## The next action

1. Push this scaffold to `github.com/Shaggydesai/platform-engineering-lab` (empty remote confirmed).
2. Confirm C: is solid state — ADR-0004 has the command.
3. Create the AWS and GCP accounts with budget alarms **before** any resource exists (ADR-0003).
4. `make doctor` until it passes.

Then Module 01: build the three VMs from code.

## Module 00 checklist

- [x] Repository structure defined
- [x] ADR-0001: three substrates, one platform definition
- [x] ADR-0002: GitOps ownership model (decided **before** anything is installed)
- [x] ADR-0003: cost guardrails for free-tier-only cloud
- [x] `.gitattributes` to kill the CRLF/BOM class of bugs permanently
- [x] Laptop specs captured → on-prem substrate chosen (ADR-0004)
- [ ] Confirm C: is solid state (`Get-PhysicalDisk`)
- [ ] Install missing workstation tools until `make doctor` passes
- [ ] AWS account + budget alarm at $5
- [ ] GCP account + budget alert at ₹400
- [ ] `make doctor` passes on the workstation

## Session log

Keep this short. One line per session: what you did, what broke, what is next.

| Date | Module | What happened | Next |
|:--|:--|:--|:--|
| 2026-10-17 | 00 | Project restarted. Decisions and scaffold written before any cluster exists. | Capture laptop specs, create repo |
| 2026-10-22 | 00 | Hardware captured: 32 GB, 12 threads, C: 106 GB SSD, D: 625 GB HDD. ADR-0004 fixes the substrate: 3 kubeadm VMs on the SSD, because etcd on a mechanical disk is a known failure mode. Repo created, scaffold ready to push. | Push scaffold, budget alarms, `make doctor` |
