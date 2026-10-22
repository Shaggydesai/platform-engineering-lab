# ADR-0006: libvirt/KVM instead of VMware Workstation

**Status:** Accepted
**Date:** 2026-10-22
**Supersedes:** the hypervisor choice in ADR-0004 and the Packer exception in ADR-0005. The VM
sizing, the SSD placement and the WSL-as-workstation decision all stand unchanged.

## Context

ADR-0004 chose VMware Workstation because it was already installed and familiar. Familiarity is
not an engineering argument, and within a day the choice had already produced one correction:
Packer's `vmware-iso` builder executes local VMware binaries, so it cannot run in WSL, which forced
a Windows/Linux boundary into the middle of the build.

A check confirmed that WSL2 on this machine exposes `/dev/kvm` and reports `KVM acceleration can be
used`, with systemd running. That makes libvirt a genuine option rather than a theoretical one.

## Decision

**The on-prem substrate is QEMU/KVM managed by libvirt, provisioned by Terraform, inside WSL.**

VMware Workstation is no longer part of this project.

### The argument that decided it

Not the all-Linux toolchain, pleasant as that is. **Terraform can own Layer 0 properly.**

Under VMware, `scripts/onprem-vms.sh` was a hand-rolled script imitating infrastructure-as-code:
no state, no plan, no dependency graph, no way to see a change before making it. ADR-0002 assigns
Layer 0 to Terraform, and on VMware Workstation that assignment could not actually be honoured —
there is no provider worth using.

With libvirt there is one, and the result is real:

```hcl
resource "libvirt_domain" "node" {
  for_each  = local.nodes
  memory    = each.value.memory_mb
  vcpu      = each.value.cpus
  cloudinit = libvirt_cloudinit_disk.node[each.key].id
}
```

`terraform plan` shows what will change. `terraform destroy` removes it. State makes the lab
diffable. That is the difference between claiming to practise IaC and practising it.

### The second-order benefit: the on-prem path now matches the cloud path

Nodes are configured by **cloud-init**, which is how EC2 and GCE provision instances. The base
image is Ubuntu's official **cloud image**, the same artefact family the clouds publish. So
Modules 08 and 09 stop being "a different thing we also do" and become the same pattern with a
different provider — which is exactly the thesis of ADR-0001, and VMware was quietly undermining
it.

This also removes the ISO autoinstall entirely. No `boot_command` typing a GRUB line with
timing-sensitive `<wait>` values — the single most fragile step in the previous design, and the one
most likely to differ between machines. Image build time drops from roughly twenty minutes to
about three.

### What the old design did better, recorded honestly

| | VMware | libvirt in WSL |
|:--|:--|:--|
| Virtualisation layers | Hyper-V → VMware → guest | Hyper-V → WSL2 → KVM → guest |
| Reaching a VM from a Windows browser | direct, via vmnet8 | one forwarding rule from WSL |
| Disk freed when a VM is destroyed | immediately, on NTFS | inside `ext4.vhdx`, which keeps its high-water mark until compacted |
| Watching the first boot | GUI console | `virsh console`, serial output |

The first row is the real cost: one more nesting layer. It should be **measured** once the nodes
exist rather than assumed, and the measurement recorded here.

The third row is handled by `make reclaim`, which shuts WSL down and compacts the virtual disk.
It is a documented maintenance step, not a surprise.

## Consequences

**Good.** Terraform genuinely owns Layer 0. cloud-init on both on-prem and cloud. No Windows/Linux
boundary anywhere in the build. Faster, more reliable image builds. KVM and libvirt are what the
industry actually runs — EC2 Nitro, GCE, OpenStack and Proxmox are all KVM underneath — so the
skill transfers in a way VMware Workstation's does not.

**Costly.** An additional virtualisation layer. WSL's memory limit must be raised in `.wslconfig`,
because the default is half of host RAM and the nodes need more than that. Reaching a node from a
Windows browser needs a forwarding rule.

**Risk.** libvirt inside WSL is a less-travelled path than libvirt on bare Linux; networking or
systemd quirks may appear. Mitigated by the fact that the whole substrate is now destroyable and
rebuildable by `terraform apply` in minutes, so experiments are cheap.

## Prerequisites this introduces

```ini
# C:\Users\<user>\.wslconfig   - the default limit is half of host RAM
[wsl2]
memory=26GB
processors=10
nestedVirtualization=true
autoMemoryReclaim=gradual
```

followed by `wsl --shutdown`. `make doctor` checks the resulting limit and fails if the nodes
would not fit.
