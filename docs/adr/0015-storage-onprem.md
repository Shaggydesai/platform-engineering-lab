# ADR-0015: node-local dynamic storage, and what that costs

**Status:** Accepted
**Date:** 2026-10-29
**Decides:** how a PersistentVolumeClaim gets a volume on the on-prem cluster, and what the
cluster is therefore unable to do.

## Context

Nothing has needed persistence yet. ShopVerse in Module 06 will, and a stock Helm chart with
`persistence.enabled` expects a *default* StorageClass to exist — otherwise its PVC sits
`Pending` with no class to satisfy it and the chart appears to hang.

The on-prem nodes have one disk each (35 GB on the workers) on a laptop. There is no SAN, no NFS
server, and no cloud volume service.

## Options

**Nothing, and `emptyDir`.** Honest for stateless work and useless the moment a database appears.

**Static `hostPath` volumes, pre-created by Ansible.** No provisioner, no new component. But
every PVC becomes a hand-made PV with a hand-made path, which is exactly the kind of by-hand
object ADR-0002 Rule 3 exists to prevent.

**Rancher's local-path-provisioner.** Dynamic provisioning into a directory on whichever node
the pod is scheduled to. One small Deployment. Volumes are node-local.

**Longhorn.** Replicated block storage, so a volume survives losing a node, which is the honest
answer to the failover question ADR-0013 just measured. It wants iSCSI on every node, a
meaningful amount of RAM, and replica capacity on 35 GB disks. It would dominate the lab rather
than serve it.

**NFS exported from the WSL host.** Would give shared read-write-many and make the laptop a
single point of failure for the cluster's storage, while teaching nothing that transfers.

## Decision

**local-path-provisioner v0.0.37**, as the default StorageClass named `platform-local`.

### 1. From a git source, because Rancher publishes no Helm repository

The chart exists only inside `rancher/local-path-provisioner` under
`deploy/chart/local-path-provisioner`; the README installs it from a local clone. Argo CD renders
a Helm chart from a git source natively, so the Application points at the upstream repository
directly.

The alternative was one of the third-party republishes on Artifact Hub — `containeroo` at chart
0.0.38, `kir4h` at 0.0.35. Neither is Rancher. For a component that creates and deletes
directories on every node as root, "someone repackaged it" is not a supply chain.

Worth noting as a near-miss: `0.0.38` on Artifact Hub is that publisher's **chart** version, not
an app version. `git ls-remote` shows no `v0.0.38` tag upstream at all. Reading it as a newer
release and pinning to it would have failed, and the failure would have looked like a broken
chart rather than a version that does not exist.

This is a **variant** of ADR-0010's wrapper pattern, not the pattern: there is no local
`Chart.yaml` and therefore no `Chart.lock` digest, because a wrapper chart needs a Helm
repository to depend on. The per-environment values overlay works exactly as everywhere else.

### 2. Pinned to a tag, with the commit recorded — detection, not prevention

`targetRevision: v0.0.37`, and `clusters/onprem/nodes.json` records
`49b2be8e26d6d34c9afaa21fa33108d2e82f8955`, verified with `git ls-remote` rather than copied from
a release page.

Argo CD follows wherever the tag points. So if upstream re-tags, this cluster syncs different
code under the same version number. `make gitops-check-pins` resolves the tag and compares it
against the recorded commit, so a move is **noticed** — but it is not **prevented**, and the
difference matters: the Gateway API bundle is pinned by content digest and genuinely cannot do
this. Pinning `targetRevision` to the SHA would close the gap and cost the readability of a
version number in the Application; the check was judged enough for a lab, and that judgement is
the thing to revisit rather than the mechanism.

### 3. `volumeBindingMode: WaitForFirstConsumer`, stated rather than inherited

It is the chart's default. It is written out in the overlay anyway, because it is the single most
important setting here and its absence is the hardest thing to diagnose.

`WaitForFirstConsumer` delays creating the volume until a pod that uses it has been scheduled, so
the directory is made on the node the pod landed on. With `Immediate`, the volume is created
first — on whichever node the provisioner chose, with no input from the scheduler — and the pod
is then permanently unschedulable if it cannot be placed there. That presents as a `Pending` pod
with a node-affinity message, and nothing about it points at a storage setting.

### 4. The class is named for the platform, not the implementation

`platform-local`, not `local-path`. A workload that asks for `platform-local` keeps working if
the provisioner behind it is replaced. One that asks for `local-path` has the implementation
written into every PVC in the cluster, and replacing it becomes a migration.

### 5. Default class, `reclaimPolicy: Delete`

Default so that a stock chart with `persistence.enabled` works without per-chart configuration.
`Delete` because `Retain` on a cluster that gets rebuilt leaves orphaned directories on the nodes
and `Released` PVs that no new claim can bind — the storage form of the orphaned-disk problem
ADR-0003 forbids in the cloud.

### 6. Only the values this project has an opinion about

Everything else stays at the chart's default deliberately, including the node path
(`/opt/local-path-provisioner`). This chart cannot be rendered in the environment where these
files were written, so a value set from a guessed structure is a sync failure found by the
operator rather than by the author. `make gitops-render` shows what actually lands; anything
worth moving moves after that has been read.

## What this cluster now cannot do

The part that matters more than the decision.

**A volume lives on one node, and a dead node takes its data with it.** ADR-0013 measured
ingress failing over in ~15 seconds. Storage does not fail over at all. If `k8s-w02` dies while
holding a PVC, the pod cannot be rescheduled anywhere useful — the volume exists only there.
This is not a defect in the provisioner; it is what node-local means.

**No `ReadWriteMany`.** Two pods on different nodes cannot share a volume. Any chart whose
default assumes RWX will fail, and that failure is correct.

**No snapshots, no resize, no backup.** There is no CSI driver here, so the
VolumeSnapshot machinery does not apply.

**The contrast with the cloud is sharper here than it was for ingress.** On GKE and EKS a
`type: LoadBalancer` Service and a PVC are both one field — but a cloud volume is a *network*
device: it detaches from a failed node and reattaches elsewhere, and the pod moves with its
data. That single property is most of what people mean by "cloud native storage". On-prem it
takes replication to get it, which is Longhorn, which is a module of its own.

## Consequences

- **Longhorn is parked, not rejected.** It is the honest answer to node-local storage and the
  natural partner to the failover work already done. It needs iSCSI, RAM, and replica capacity
  this laptop does not comfortably have, so it waits for a module that can afford it.
- `make gitops-check-pins` gained a second section for git-sourced charts, which the original
  loop could not see at all because there is no local `Chart.yaml` to read a dependency from.
- The helper-pod image the provisioner uses to create and remove directories is left at the
  chart's default tag, which this project has not inspected or pinned. Parked with the exact
  command to find it.
- Nothing in the cloud overlays. `gitops/environments/{gcp,aws}/local-path.yaml` exist stating
  that, so a missing file never has to be read as either "not yet" or "not applicable".

---

## First sync, 2026-10-29: the AppProject refused it

```
APP               PROJECT   SYNC     HEALTH   REVISION
local-path        platform  Unknown  Unknown  -
```

Not a sync failure — a **rejection**. `Unknown/Unknown` with no revision at all means Argo CD
never got as far as reading the repository. The `platform` AppProject lists `sourceRepos`, and it
contained one entry: this repository. An Application rendering a chart from
`github.com/rancher/local-path-provisioner.git` was therefore not permitted to read its own
source.

This is the boundary working, and it is worth recording because the comment above that list in
`gitops/bootstrap/projects.yaml` already predicted it: *"An AppProject is a boundary, not a
folder. It answers three questions about every Application inside it: which repositories may it
read, where may it deploy, and what kinds of object may it create."* Adding an external chart
source is supposed to cost a deliberate edit to that boundary, and it did.

Two details about the fix:

**The entry is one repository, not `github.com`.** A platform component permitted to render a
chart from anywhere on GitHub is a platform component permitted to render anything.

**It is applied by Ansible, not by Argo CD.** `projects.yaml` is the seam (ADR-0009, Decision 1):
Argo CD cannot own the object that defines what Argo CD may do. So this change needs
`make onprem-up TAGS=argocd` and will not arrive from a `git push` alone — which is the one case
where "nothing in this cluster is installed by hand" has a genuine exception, and the reason the
exception exists.

## What the render showed, 2026-10-29

`make gitops-render CHART=local-path` fetched `v0.0.37`, confirmed it resolves to
`49b2be8e26d6…`, and rendered. The StorageClass arrived as intended:

```
NAME                       PROVISIONER                                       RECLAIMPOLICY   VOLUMEBINDINGMODE
platform-local (default)   cluster.local/local-path-local-path-provisioner   Delete          WaitForFirstConsumer
```

Three things in the rendered output that were not visible before, and would not have been
guessable:

**The node path is `/opt/local-path-provisioner`**, from the chart's default `nodePathMap`, now
confirmed rather than assumed. ADR section 6 said this value was left alone because the chart
could not be rendered where these files were written; it can be rendered now, so moving it is
available as a decision. Leaving it is also fine — the point was never the path.

**The setup script is `mkdir -m 0777 -p "$VOL_DIR"`.** Every provisioned volume directory is
world-writable on the node. That is upstream's choice and it is what lets a container running as
an arbitrary non-root UID write to its own volume without an fsGroup dance. It also means any
process on that node can read and write any volume's contents. On a single-tenant lab this is
acceptable; it is worth knowing before a tenant workload is given a PVC, because it is a property
of the provisioner and not something a PodSecurity setting fixes.

**`ALLOWVOLUMEEXPANSION` is `true`.** For a hostPath-backed directory there is nothing to expand —
the volume is a folder on a filesystem whose size it does not control. Treat a successful PVC
resize here as meaningless rather than as working, and do not build anything that relies on it.

## Verified, 2026-10-29

```
$ kubectl -n pvc-test get pvc t
t      Pending                      platform-local
  Normal  WaitForFirstConsumer  waiting for first consumer to be created before binding

$ kubectl -n pvc-test get pvc,pod -o wide        # after creating a pod that mounts it
t      Bound   pvc-3d81f8dd-…   1Gi   RWO   platform-local
pod/w  1/1     Running                             k8s-w01

$ kubectl -n pvc-test exec w -- sh -c 'echo hello > /data/f && cat /data/f'
hello

$ kubectl get pv -o custom-columns=PV:…,NODE:…,PATH:…
pvc-3d81f8dd-…   k8s-w01   /opt/local-path-provisioner/pvc-3d81f8dd-…_pvc-test_t
```

Four claims in this ADR were tested rather than asserted:

**The default class works.** The PVC named no `storageClassName` and was assigned
`platform-local` — which is the entire reason section 5 makes it the default, and what lets a
stock chart with `persistence.enabled` work here untouched.

**`WaitForFirstConsumer` behaves as section 3 describes.** The claim sat `Pending` with that
exact event for 49 seconds and bound only once a pod existed to be scheduled. `Pending` there is
the correct state, not a fault — which is worth knowing because it looks identical to a broken
provisioner for as long as nobody creates a consumer.

**The volume is node-local, concretely.** The PV's node affinity names `k8s-w01` and its path
names one directory on that node's disk. Nothing about this volume exists anywhere else. The
"what this cluster now cannot do" section above is not a caveat about the technology in general;
it is a property of this exact PV.

**The path confirms the chart default**, `/opt/local-path-provisioner/<pv>_<namespace>_<claim>`.
The naming is useful: a directory found on a node can be traced back to the claim that made it,
which matters when cleaning up after a cluster that was rebuilt without draining.
