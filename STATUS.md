# Where we are

> **This file is the answer to "what was I doing?"** Update it at the end of every session,
> before you close the laptop. It takes thirty seconds and it is the reason this project will
> not stall like the last one.

**Last updated:** 2026-10-17
**Current module:** 00 — Foundations (repository, decisions, guardrails)
**Overall progress:** 0 / 12 modules complete

---

## Right now

| | |
|:--|:--|
| **On-prem cluster** | not built — substrate not yet chosen (waiting on RAM/disk figures) |
| **GCP cluster** | not built |
| **AWS cluster** | not built |
| **Argo CD** | not installed |
| **ShopVerse running** | no |
| **Monthly spend** | ₹0 |

## The next action

Create the empty GitHub repository `platform-engineering-lab`, then push this scaffold.
After that: Module 00 checklist below.

## Module 00 checklist

- [x] Repository structure defined
- [x] ADR-0001: three substrates, one platform definition
- [x] ADR-0002: GitOps ownership model (decided **before** anything is installed)
- [x] ADR-0003: cost guardrails for free-tier-only cloud
- [x] `.gitattributes` to kill the CRLF/BOM class of bugs permanently
- [ ] Laptop specs captured → on-prem substrate chosen
- [ ] AWS account + budget alarm at $5
- [ ] GCP account + budget alert at ₹400
- [ ] `make doctor` passes on the workstation

## Session log

Keep this short. One line per session: what you did, what broke, what is next.

| Date | Module | What happened | Next |
|:--|:--|:--|:--|
| 2026-10-17 | 00 | Project restarted. Decisions and scaffold written before any cluster exists. | Capture laptop specs, create repo |
