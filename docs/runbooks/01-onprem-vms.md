# Runbook: on-prem nodes

**Owner:** Terraform (Layer 0 in ADR-0002)
**Module:** 01
**Substrate:** QEMU/KVM via libvirt, inside WSL (ADR-0006)

## What this does

Produces three Ubuntu 24.04 nodes from one golden image, each with its own identity and a fixed
address, in about five minutes — repeatably, from code.

```text
Ubuntu cloud image (official, cloud-init ready)
   │   packer build          ~3 min, once
   │     hardening, containerd (systemd cgroups), kubeadm/kubelet/kubectl held,
   │     kernel modules, sysctls, swap off, chrony, qemu-guest-agent
   │     seal: machine-id emptied, host keys removed, cloud-init state cleared
   ▼
packer/ubuntu-2404/output/ubuntu-2404-k8s.qcow2      (20 GB base)
   │
   │   terraform apply       ~30 s, every time
   │     libvirt NAT network
   │     one copy-on-write volume per node, sized up from the base
   │     one cloud-init seed per node: hostname, SSH key, /etc/hosts
   │     verification: every node answers SSH, no two share a machine-id
   ▼
k8s-cp01 192.168.100.10   k8s-w01 .11   k8s-w02 .12
```

## Why it is built this way

**The image holds what is common; cloud-init holds what is unique.** Hostname, machine-id, SSH
host keys and address are identity. Bake identity into an image and the clones collide — two
machines sharing a machine-id fight over DHCP leases and confuse journald, and it surfaces hours
later looking unrelated.

**Terraform owns it, not a script.** `terraform plan` shows what will change before it changes;
`terraform destroy` removes everything; state makes the lab diffable. ADR-0002 assigns Layer 0 to
Terraform and this is where that becomes true rather than aspirational.

**cloud-init, from Ubuntu's cloud image.** The same mechanism and the same artefact family that
EC2 and GCE use. Modules 08 and 09 are then the same pattern with a different provider rather
than a different skill.

**Addresses are declared in `nodes.json` and applied by cloud-init inside the guest.** An earlier
draft used libvirt DHCP reservations, which meant pinning MAC addresses and depending on lease
timing — two more things that can be subtly wrong. Netplan inside the node is one fewer moving
part, and the addresses still live in version control, which was the whole point. No DHCP server
configuration is ever edited by hand either way.

**`nodes.json` is read by both Terraform and (from Module 03) Ansible**, so the inventory cannot
drift from reality.

## Run it

```bash
make tools          # once: qemu, libvirt, terraform, packer. Adds you to the libvirt group.
exec su - $USER     # group membership needs a new login shell
make doctor         # must pass, including /dev/kvm and WSL memory
make image          # ~3 min
make onprem-vms     # ~2 min
make onprem-vms-status
```

Prerequisite, once, from PowerShell — WSL defaults to half your RAM and the nodes need 20 GB:

```ini
# C:\Users\<user>\.wslconfig
[wsl2]
memory=26GB
processors=10
nestedVirtualization=true
autoMemoryReclaim=gradual
```

then `wsl --shutdown`. `make doctor` fails loudly if this was not done.

## The gate for this module — **passed 2026-10-22**

```bash
make onprem-vms-destroy
make onprem-vms
```

Passes when all three nodes return on `.10/.11/.12` with the right hostnames and three distinct
machine-ids. Terraform's verification step checks the machine-ids itself and fails the apply if
two match. Until that round trip works, Module 02 does not start.

The passing run, for reference — 28 seconds from `apply` to verified:

```text
192.168.100.10  k8s-cp01  9ef4200f38314554b1ba657b05921780
192.168.100.11  k8s-w01   25e924f7fde747f39e64749fc04c89df
192.168.100.12  k8s-w02   5315dce9c2764cc6bb3ff9fabe48b000
all nodes reachable, machine-ids unique
```

## How it breaks

| Symptom | Cause | Fix |
|:--|:--|:--|
| Domain runs, CPU time flat at ~5s, no lease, no ping, no SSH | the disk `driver` block was omitted, so libvirt defaulted to `type="raw"` and QEMU read the qcow2 header as a partition table | set `driver = { name = "qemu", type = "qcow2" }` on the disk. Confirm with `sudo grep 'driver.:.raw' /var/log/libvirt/qemu/<node>.log` |
| `/dev/kvm not writable` | not in the kvm/libvirt groups yet | `make tools`, then `exec su - $USER` |
| `cannot reach qemu:///system` | same, or libvirtd not running | `sudo systemctl enable --now libvirtd` |
| `storage pool default missing` | fresh libvirt install | `make tools` defines and starts it |
| Packer hangs at `Waiting for SSH` | the cidata seed was not read | check `variables.auto.pkrvars.hcl` has a real key; `packer build -debug` |
| `COW volume smaller than backing file` | a node's `disk_gb` is below the Packer `disk_size` | nodes size **up** from the 20 GB base, never down |
| Node pings but SSH is refused | cloud-init is still running; it writes the authorized key late in first boot | wait 20 s, or `virsh console <node>` to watch it finish |
| Node never answers after a host reboot | domains are `autostart = false` by design, so nothing starts behind your back | `make onprem-vms` — it is idempotent and starts them |
| Nodes share a machine-id | the image was not sealed | re-run `make image`; `99-seal.sh` empties `/etc/machine-id` |
| WSL disk keeps growing after destroys | `ext4.vhdx` keeps its high-water mark | `make reclaim` |
| A node is slow | three nesting layers: Hyper-V → WSL2 → KVM → guest | expected; measure before trading WSL away (ADR-0006) |

## Known caveats

**The cloud-init seed lives in /tmp.** `libvirt_cloudinit_disk` in 0.9 has no `pool`
attribute and writes its ISO to `/tmp/terraform-provider-libvirt-cloudinit/`. That is fine
while a node runs - cloud-init only reads it on first boot - but if the file is cleaned away,
the domain will refuse to start because one of its disks is missing. If that happens,
`terraform apply` recreates the ISO.

**There is no serial console or graphics device yet.** `virsh console` and `virsh screenshot`
will not work until those are added to `devices`. `make onprem-diagnose` falls back to the
QEMU log, which is where the raw/qcow2 bug above was actually found.

## Reaching a node from a Windows browser

The nodes live on libvirt's NAT network inside WSL, so Windows cannot route to them directly. One
forwarding rule covers the whole platform, because all ingress arrives on a single Gateway address
and SNI separates the hostnames:

```bash
# from WSL, once the Gateway has an address (Module 05)
socat TCP-LISTEN:8443,fork,reuseaddr TCP:192.168.100.200:443
```

Then point Windows at `localhost:8443` with a `hosts` entry for the platform hostname. This is set
up properly in Module 06, when there is something to look at.

## Cost of a rebuild

About two minutes for the nodes, three more if the image also needs rebuilding. That number is the
point: when rebuilding is cheap you stop protecting the cluster and start experimenting with it.
