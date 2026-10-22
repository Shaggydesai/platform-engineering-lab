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
   │   terraform apply       ~2 min, every time
   │     libvirt NAT network with static DHCP reservations
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

**Addresses are static DHCP reservations declared in `nodes.json`.** The nodes boot with plain
DHCP, exactly as a cloud instance does, while the addresses are fixed in version control. No DHCP
server configuration is ever edited by hand.

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

## The gate for this module

```bash
make onprem-vms-destroy
make onprem-vms
```

Passes when all three nodes return on `.10/.11/.12` with the right hostnames and three distinct
machine-ids. Terraform's verification step checks the machine-ids itself and fails the apply if
two match. Until that round trip works, Module 02 does not start.

## How it breaks

| Symptom | Cause | Fix |
|:--|:--|:--|
| `/dev/kvm not writable` | not in the kvm/libvirt groups yet | `make tools`, then `exec su - $USER` |
| `cannot reach qemu:///system` | same, or libvirtd not running | `sudo systemctl enable --now libvirtd` |
| `storage pool default missing` | fresh libvirt install | `make tools` defines and starts it |
| Packer hangs at `Waiting for SSH` | the cidata seed was not read | check `variables.auto.pkrvars.hcl` has a real key; `packer build -debug` |
| `COW volume smaller than backing file` | a node's `disk_gb` is below the Packer `disk_size` | nodes size **up** from the 20 GB base, never down |
| `wait_for_lease` times out | the node did not DHCP | `virsh console <node>` and watch the boot |
| Nodes share a machine-id | the image was not sealed | re-run `make image`; `99-seal.sh` empties `/etc/machine-id` |
| WSL disk keeps growing after destroys | `ext4.vhdx` keeps its high-water mark | `make reclaim` |
| A node is slow | three nesting layers: Hyper-V → WSL2 → KVM → guest | expected; measure before trading WSL away (ADR-0006) |

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
