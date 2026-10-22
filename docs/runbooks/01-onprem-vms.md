# Runbook: on-prem VMs

**Owner:** Terraform/Packer layer (Layer 0 in ADR-0002)
**Module:** 01

## What this does

Produces three identical Ubuntu 24.04 nodes from one golden image, each with its own identity and
a stable address, in roughly ten minutes of unattended work.

```text
packer build                     once, ~20 min
   │   Ubuntu autoinstall (http/user-data) - no installer screens
   │   base packages, containerd, kubeadm/kubelet/kubectl (held), hardening
   │   seal: machine-id emptied, SSH host keys removed, cloud-init cleaned
   ▼
C:/VMs/templates/ubuntu-2404-k8s/ubuntu-2404-k8s.vmx
   │
   │   onprem-vms.ps1 -Action create     every time, ~10 min
   │     snapshot 'base' → three linked clones
   │     resize per role, uuid.action=create (new UUID + MAC)
   │     boot → read DHCP lease → discover NAT subnet
   │     set hostname, machine-id, SSH host keys, static IP, /etc/hosts
   │     reboot onto the static address and verify
   ▼
k8s-cp01 .10   k8s-w01 .11   k8s-w02 .12
```

## Why it is built this way

**The image holds everything common; the clone script holds everything unique.** Hostname,
machine-id, SSH host keys and IP address are identity. Bake identity into an image and the clones
collide — two machines with one machine-id fight over DHCP leases and confuse journald, and it
surfaces hours later as something that looks unrelated.

**The NAT subnet is discovered, not configured.** The first clone boots on DHCP, reports its
address through open-vm-tools, and the script derives the subnet from it. Static addresses are
then assigned at `.10`, `.11`, `.12` — VMware's NAT pool starts at `.128`, so there is no overlap
and no reason to ever touch `vmnetdhcp.conf`. The previous attempt at this platform spent an
evening editing that file with PowerShell string replacement; this avoids the entire category.

**Remote commands are base64-encoded.** Sending a bash script through PowerShell, then `ssh`, then
`sudo`, means three layers of quoting. Encoding removes the problem rather than escaping around
it.

**Templates go on C:.** See ADR-0004 — etcd fsyncs every write and D: is mechanical.

## Run it

```powershell
# one-time: build the golden image
cd packer\ubuntu-2404
packer init .
packer build .                       # ~20 minutes, watch the console on the first run

# every time: produce the three nodes
cd ..\..
.\scripts\onprem-vms.ps1 -Action create
.\scripts\onprem-vms.ps1 -Action status
.\scripts\onprem-vms.ps1 -Action destroy -Force
```

Before the first build, create `packer/ubuntu-2404/variables.auto.pkrvars.hcl`:

```hcl
ssh_public_key = "ssh-ed25519 AAAA... sagar@workstation"
```

Without it the image keeps password authentication enabled and prints a warning.

## The gate for this module

Destroy everything, rebuild it, and confirm the result is identical:

```powershell
.\scripts\onprem-vms.ps1 -Action destroy -Force
.\scripts\onprem-vms.ps1 -Action create
```

Passes when all three nodes come back on `.10/.11/.12`, with the right hostnames, three distinct
machine-ids (the script checks this and fails loudly if not), and SSH working by key. Until that
round trip works, Module 02 does not start.

## How it breaks

| Symptom | Cause | Fix |
|:--|:--|:--|
| Packer waits forever at `Waiting for SSH` | autoinstall did not start — the boot command mistyped into GRUB | Watch the console; the GRUB line should show `autoinstall ds=nocloud-net;s=http://...`. Increase the `<wait>` values on a slow disk. |
| `404` on the ISO URL | Ubuntu published a new point release | Update `iso_url`; the checksum is read from `SHA256SUMS` so it needs no change |
| `getGuestIPAddress` never returns | open-vm-tools missing or not started | It is in `user-data` packages; check `systemctl status open-vm-tools` on the console |
| Two nodes get the same address | the template was cloned without `uuid.action = "create"` | the script sets it; if you cloned by hand in the GUI, destroy and re-run |
| SSH refuses the key after a rebuild | host key changed, as it should | `ssh-keygen -R <ip>`; the script already ignores known_hosts |
| Node boots but has no network after reboot | cloud-init re-applied its own netplan | `99-disable-network-config.cfg` prevents it; confirm it exists |
| `.vmx` will not load | file written with a BOM | the script writes ASCII explicitly; do not edit `.vmx` files with `Set-Content` |

## Cost of a rebuild

About ten minutes, unattended. That number matters: once rebuilding is cheap, you stop protecting
the cluster and start experimenting with it, which is the entire point of having a lab.
