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

# autoMemoryReclaim is NOT a [wsl2] key. Put it here or WSL prints
# "Unknown key 'wsl2.autoMemoryReclaim'" on every start and ignores it.
[experimental]
autoMemoryReclaim=gradual
```

then `wsl --shutdown`. `make doctor` fails loudly if this was not done.

## After WSL restarts

Whenever WSL shuts down — `wsl --shutdown`, a Windows restart, or just long enough idle — libvirt
stops with it and the nodes are left defined but not running. SSH then fails with **no route to
host**, because the `virbr1` bridge is gone too.

```bash
make onprem-vms            # idempotent: starts what exists, creates only what is missing
make onprem-vms-status
```

Nothing is lost. The node disks are files in the libvirt pool, so anything on them — including
`/var/lib/etcd` — survives. The control plane comes back by itself, because the kubelet is a
systemd unit and the static pod manifests are on disk; no `kubeadm` command is needed or wanted.

This is worth doing deliberately once, because "the host went away without warning" is the one
failure a laptop lab will hand you repeatedly, and knowing the recovery is one idempotent command
is the difference between a lab you use and a lab you are afraid of.

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
| Node pings but SSH is refused | cloud-init is still running; it writes the authorized key late in first boot | wait 20 s, or `make onprem-boot-log NODE=<node>` to watch it finish |
| The console log is empty while the domain runs | nothing reached the serial port, so the guest never got as far as GRUB | the disk is the suspect, not the network — check the `driver` row above |
| Node never answers after a host reboot | domains are `autostart = false` by design, so nothing starts behind your back | `make onprem-vms` — it is idempotent and starts them |
| Nodes share a machine-id | the image was not sealed | re-run `make image`; `99-seal.sh` empties `/etc/machine-id` |
| WSL disk keeps growing after destroys | `ext4.vhdx` keeps its high-water mark | `make reclaim` |
| A node is slow | three nesting layers: Hyper-V → WSL2 → KVM → guest | expected; measure before trading WSL away (ADR-0006) |

## Known caveats

**The seed ISO is staged in /tmp and then uploaded into the pool.** `libvirt_cloudinit_disk`
writes its ISO to `os.TempDir()` and exposes `path` as computed only — there is no attribute to
redirect it, which the provider source confirms. Inside WSL that is `/tmp`, cleared on every
shutdown, and a domain whose seed file has vanished does not boot badly, it refuses to start.

So `libvirt_volume.seed` uploads it into the storage pool and the domain attaches the pool
volume. A node can then be started with plain `virsh start`, with no Terraform involved.

What remains: after `/tmp` is cleared, `terraform apply` recreates the staging ISO and rewrites
the pool volume with byte-identical content. The volume's path is derived from its name, so the
domain's XML does not change and **the nodes are not rebooted** by it. Expect
`3 to add, 3 to change` on the first apply after a WSL restart; that is this, and it is cheap.

**"Update in-place" on a domain still reboots it.** Adding the console was planned as
`3 to change, 0 to destroy` — which reads like a hot attach. It is not: the console log's first
entry is a complete boot, kernel line one onward, timestamped at the moment of the apply. The
provider redefined the domain and restarted it.

This is harmless today and will not be from Module 02 onward. **Once Kubernetes is running, a
Terraform change to `devices`, `cpu`, `memory` or `os` reboots every node it touches**, and three
nodes rebooting at once takes etcd with it. From Module 02:

```bash
make onprem-vms-plan          # read it. "update in-place" on a domain means a reboot.
```

and if a domain must change, drain and do them one at a time:

```bash
kubectl drain k8s-w01 --ignore-daemonsets --delete-emptydir-data
terraform -chdir=terraform/onprem apply -target='libvirt_domain.node["k8s-w01"]'
kubectl uncordon k8s-w01
```

**There is no graphics device, deliberately.** `virsh screenshot` will not work. For a headless
server a text console is strictly more useful — it is copyable, greppable, and recorded — and a
VNC port is one more listening socket to secure for no benefit.

## Watching a node boot

Every node has a serial console, and it does two things at once:

```bash
make onprem-console  NODE=k8s-cp01    # interactive. Enter for a login prompt, Ctrl-] to detach
make onprem-boot-log NODE=k8s-cp01    # the recorded log, followed
./scripts/console.sh k8s-cp01 --last  # just the most recent boot
```

The recording is the important half. `virsh console` only shows what happens *after* you attach,
which is useless for a boot that failed overnight — and that gap is exactly what made the
raw/qcow2 bug above take an hour to find. Everything from GRUB onward is appended to
`/var/log/libvirt/qemu/<node>-console.log`, with `append = "on"` so a reboot does not erase the
evidence of why it rebooted.

It works because Ubuntu's cloud image already boots with `console=ttyS0` on the kernel command
line; libvirt presents a console whose target type is `serial` to the guest as `ttyS0`.

The interactive side is a raw TCP chardev that libvirt binds to **127.0.0.1 only**. There is no
authentication on it and the node has a passwordless-sudo user, so it is a root shell to anything
that can reach the port. Loopback is not an accident, and it is the reason the protocol is `raw`
rather than `telnet` — raw gives `socat` a clean terminal instead of telnet negotiation bytes in
the stream.

Ports are derived from the address rather than declared, so there is no second list to keep in
sync: `.10 → 12310`, `.11 → 12311`, `.12 → 12312`.

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
