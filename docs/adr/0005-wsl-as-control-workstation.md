# ADR-0005: WSL as the control workstation

**Status:** Accepted
**Date:** 2026-10-22

## Context

The workstation is Windows; the entire platform is Linux. The previous attempt at this project ran
every command from PowerShell and paid for it continuously:

- Files written by `Set-Content` carried a UTF-8 byte-order mark, which breaks YAML parsers with
  errors that never mention a BOM.
- PowerShell wrote CRLF line endings into shell scripts and Helm templates, producing
  `bad interpreter` failures on the nodes.
- Every manifest had to be shuttled from the Windows repository to a node with `scp` and back
  again, so the repository and the cluster were regularly out of step.
- Quoting a `kubectl ... -o jsonpath` expression through PowerShell consumed real time, repeatedly.

WSL is already installed on this machine. Every one of those problems disappears when the shell
that edits the files is the same kind of shell that runs them.

## Decision

**WSL is the control workstation. Everything is driven from there.**

| Tool | Runs in | Why |
|:--|:--|:--|
| git, make, ssh | WSL | same line endings and permissions as the nodes |
| kubectl, helm, argocd | WSL | native builds, no path translation |
| Ansible (Module 03) | WSL | Ansible has no supported Windows control node |
| Terraform, Packer | WSL or Windows | either works; prefer WSL for consistency |
| VMware Workstation, `vmrun.exe` | Windows | called from WSL through interop |

The repository is cloned **inside the WSL filesystem** (`~/platform-engineering-lab`), not under
`/mnt/c`. Files on `/mnt/c` go through a translation layer that is slow and loses Unix permissions,
which breaks `chmod +x` on scripts and SSH key modes.

`scripts/onprem-vms.sh` becomes the primary VM lifecycle tool. `scripts/onprem-vms.ps1` is kept as
the Windows-native fallback for a machine without WSL; the two must stay behaviourally identical.

## Two caveats that are not obvious

**1. VMware Workstation runs slower alongside WSL2.** WSL2 requires the Windows Hypervisor
Platform, which makes VMware Workstation run as a guest of Hyper-V rather than owning the CPU's
virtualisation extensions directly. Modern Workstation supports this, but nested VMs are
measurably slower. For three small Kubernetes nodes this is acceptable; if the cluster feels
sluggish, the trade is WSL2 versus full-speed VMs, and it should be measured rather than guessed.

**2. WSL2 may not reach VMware's NAT network by default.** WSL2 is itself a virtual machine with
its own network namespace, and `vmnet8` belongs to the Windows host. If `ping 192.168.x.10` from
WSL fails, enable mirrored networking in `C:\Users\<user>\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
```

then `wsl --shutdown` and reopen. `scripts/onprem-vms.sh` checks this explicitly and prints that
instruction rather than failing with a timeout, because an unexplained SSH timeout is the kind of
thing that costs an evening.

## Consequences

**Good.** One shell, one set of line endings, one way to quote things. Ansible, make and the whole
Linux toolchain work natively. The repository can be edited in VS Code on Windows through the WSL
remote extension while every command runs Linux-side.

**Costly.** VM performance is reduced by the Hyper-V requirement, and WSL networking needs the
check above.

**Risk.** Two implementations of the VM script can drift. Mitigated by keeping the bash version
primary and treating the PowerShell one as a fallback that is only touched when the bash one
changes.
