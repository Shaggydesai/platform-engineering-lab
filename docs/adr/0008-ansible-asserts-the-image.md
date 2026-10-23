# ADR-0008: Ansible asserts the image's work; it does not repeat it

**Status:** Accepted
**Date:** 2026-10-23
**Decides:** the boundary between what Packer configures and what Ansible configures, now that
both could legitimately own machine-level settings.

## Context

ADR-0002 assigns Layer 1 — "OS, container runtime, kubeadm, kubelet" — to Ansible. Module 01
then built a Packer image that already does most of that: swap off, `br_netfilter` and `overlay`,
the sysctls, containerd with the systemd cgroup driver, kubeadm/kubelet/kubectl installed and
held, chrony, ufw disabled, identity sealed.

So when Module 03 writes Ansible roles, there is an obvious question the roadmap did not answer:
does Ansible configure those things, or assume them?

Doing both is the tempting answer and the wrong one. If Packer sets `SystemdCgroup = true` and an
Ansible role also sets it, then the true value is whichever ran last, and the two will eventually
disagree — someone edits one and not the other, and the symptom appears on a rebuilt node weeks
later. That is precisely the failure ADR-0002 Rule 4 exists to prevent: **one source of truth per
resource**. A setting with two owners has no owner.

## Options considered

**Ansible owns machine configuration; the image is a plain Ubuntu cloud image.** Honest and
portable: the roles would work on any Ubuntu host, which matters if the substrate ever changes.
The cost is paid every single run — installing containerd and the Kubernetes packages on three
nodes takes minutes and needs network access from the guests, where the image does it once in
three minutes and every subsequent node boot is instant. It also throws away the main benefit of
a golden image, which is that a node is *already correct* when it boots rather than becoming
correct afterwards.

**Both configure it, Ansible last.** No. See above.

**Ansible assumes the image silently.** Fast, but when the image is wrong or stale the failure
surfaces as something unrelated — `kubeadm init` hanging on the kubelet, or pods OOM-killed at
sizes below their limits because the cgroup driver mismatched. Those are the exact bugs Module 01
and 02 already cost us hours on.

## Decision

**Packer owns machine configuration. Ansible asserts it, then owns cluster bootstrap.**

```text
Packer   (Module 01)   what is true of every node before it joins anything
                       swap, kernel modules, sysctls, containerd, k8s packages,
                       chrony, ufw, sealed identity

Ansible  (Module 03)   ROLE preflight   assert all of the above, fail loudly
                       ROLE control_plane  kubeadm init, from the config in Git
                       ROLE cni            Cilium, from the values in Git
                       ROLE workers        kubeadm join
                       everything that makes these three machines a CLUSTER
```

The `preflight` role **checks and never changes**. It is `scripts/doctor.sh` for nodes: every
assertion carries the sentence explaining what breaks if it is false, so a failure says "rebuild
the image, here is why" instead of "task failed".

This keeps ADR-0002's Layer 1 intact in substance — machine configuration is still owned by code,
still in this repository, still reproducible — while naming Packer rather than Ansible as the
tool that owns it. Layer 1 is a layer, not a tool.

## Consequences

**Good.** Every machine-level setting has exactly one definition, in `packer/ubuntu-2404/scripts/`.
`make onprem-up` is fast, because it does cluster work only. A wrong image fails immediately with
a specific message, rather than halfway through `kubeadm init` with a generic one. And the
assertions are a genuine regression test on the image: if a future edit to `40-harden.sh` breaks
something, the next `onprem-up` says so.

**Costly.** The Ansible roles are not portable to a node that did not come from our image. That is
an acceptable loss — the on-prem substrate is defined by ADR-0004 and ADR-0006, and the cloud
modules use managed node images where none of this applies anyway.

**Risk.** Drift in the other direction: the image gains a setting and nobody adds an assertion
for it, so a node silently loses it on rebuild. Mitigated by the rule that **a new Packer
provisioner step gets a matching `preflight` assertion in the same commit**, and by Module 02's
step 0 checklist, which is the human version of the same list.
