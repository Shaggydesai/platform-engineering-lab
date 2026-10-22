# ADR-0004: On-prem substrate and VM sizing

**Status:** Accepted
**Date:** 2026-10-22

## Context

The workstation is a laptop with:

| | |
|:--|:--|
| CPU | Intel i7-8750H — 6 cores, 12 logical processors |
| RAM | 31.9 GB |
| C: | 106 GB free, 131 GB used — **solid state** |
| D: | 625 GB free, 307 GB used — **mechanical hard disk** |
| Hypervisor | VMware Workstation Pro, already installed and known |

Two substrate options were considered:

- **k3s on small VMs** — lighter, faster to build, but a single binary that bundles the control
  plane components. Good when RAM is scarce; it hides exactly the internals this project exists to
  teach.
- **kubeadm on full VMs** — what production clusters actually are: discrete control plane
  components, static Pods, a CNI you choose and must understand.

With 32 GB of RAM the constraint that would have forced k3s does not exist.

## Decision

### Three VMs, kubeadm, on the SSD

| Node | Role | vCPU | RAM | Disk | Location |
|:--|:--|--:|--:|--:|:--|
| `k8s-cp01` | control plane + etcd | 2 | 4 GB | 30 GB | C: |
| `k8s-w01` | worker | 3 | 8 GB | 35 GB | C: |
| `k8s-w02` | worker | 3 | 8 GB | 35 GB | C: |
| | **total** | **8 / 12** | **20 / 32 GB** | **100 GB max** | |

Thin-provisioned, so real consumption will be roughly 15-20 GB per node. That leaves Windows
about 12 GB of RAM and C: roughly 45-60 GB of genuinely free space.

### The VMs live on C:, not D:

This is the most important line in this ADR, and it is not about free space.

**etcd fsyncs every write before acknowledging it.** On a mechanical disk a seek costs around
10 ms; on NVMe it is under 0.1 ms. etcd on spinning rust produces `apply entries took too long`
warnings, spurious leader elections, and an API server that feels intermittently broken for
reasons that look like networking and are not. It is one of the classic self-inflicted Kubernetes
failures, and the whole platform sits on top of it.

So: **every VM system disk goes on C:.** D: has five times the space and is the wrong place for
all of it.

### What the HDD is genuinely good for

D: is not wasted — it takes everything that is large, sequential and latency-tolerant:

- Ubuntu ISOs and the Packer output cache
- VM snapshots and exported backups
- The Velero / MinIO backup target from Module 11
- Optionally, a second data disk for Longhorn replicas later — bulk storage where throughput
  matters more than latency

### Verify the assumption before Module 01

C: is assumed to be solid state. Confirm with:

```powershell
Get-PhysicalDisk | Select-Object DeviceId, FriendlyName, MediaType, @{n='SizeGB';e={[math]::Round($_.Size/1GB)}}
Get-Partition | Where-Object DriveLetter -in 'C','D' | Select-Object DriveLetter, DiskNumber
```

If `MediaType` for the disk holding C: reports `HDD`, stop and tell me — the sizing stands but the
whole layout changes, and we would move etcd to a dedicated small SSD or accept a slower cluster
with documented consequences.

## Consequences

**Good.** The cluster is production-shaped: a real control plane, a CNI we choose, node failure we
can actually simulate by powering off a VM. Resource headroom is comfortable enough to run
ShopVerse plus the full observability stack without the lab becoming unusable.

**Costly.** Three full VMs take longer to build than k3s would. Module 01 answers that by building
them from code rather than by hand, so the cost is paid once.

**Risk.** C: has only 106 GB free, and thin provisioning hides growth until it does not. Module 01
includes a disk-usage check in `make doctor`, and container image sprawl is pruned as routine
housekeeping. If C: tightens later, the `/var/lib/containerd` directory is the first thing to move
to a second virtual disk on D: — images are large, sequential and latency-tolerant, unlike etcd.
