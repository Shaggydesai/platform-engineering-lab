# ADR-0002: GitOps ownership model

**Status:** Accepted
**Date:** 2026-10-17
**Decides:** who is allowed to create or change each class of resource, and how a resource moves
between owners.

## Context

The previous attempt at this platform installed every component by hand with `helm install`, then
tried to place those live releases under Argo CD afterwards. The result consumed weeks:

- Helm and Argo CD both believed they owned the same resources, producing permanent `OutOfSync`
  status and fields that flipped back and forth.
- Argo CD was made to manage its own installation before any layer existed that could reinstall
  Argo CD. When it broke, the tool that fixes things *was* the broken thing, and recovery required
  manually deleting and rebuilding the release.
- Nobody could answer "who owns this object?" without an investigation.

That is not a Helm problem or an Argo CD problem. It is the absence of a decision. This ADR makes
the decision first, and every later module must conform to it.

## Decision

**Four layers, each with exactly one owner. Ownership never overlaps.**

```text
Layer 0  Infrastructure          Terraform        VMs, networks, cloud clusters, IAM, DNS
Layer 1  Machine configuration   Ansible          OS, container runtime, kubeadm, kubelet
Layer 2  Cluster bootstrap       Ansible          Argo CD itself, and only Argo CD
Layer 3  Everything in-cluster   Argo CD          platform add-ons and applications
```

Rules that follow from this, and that we will not break:

1. **Nothing in Layer 3 is ever installed by hand.** No `helm install`, no `kubectl apply -f`
   against a cluster, except for deliberate, documented debugging that is reverted immediately.
   If it should exist in the cluster, it exists in Git and Argo CD puts it there.

2. **Argo CD does not manage Argo CD.** Layer 2 owns it. Self-management is a real pattern, but it
   removes your recovery path, and recovery is the thing you need most while learning. We revisit
   this in Module 11 as a deliberate exercise, with the Ansible path proven first.

3. **Every in-cluster component is a wrapper chart from the start.** A local chart that depends on
   the upstream chart and carries our values. There is never a point where a component exists as a
   command in someone's shell history. Retrofitting is what cost us the last project.

4. **One source of truth per resource.** Two paths in Git that render the same object is a bug.
   Argo CD `Application`s must not have overlapping scopes.

5. **Secrets are never committed in plaintext.** Decided in Module 07; until then, no secrets go
   into the repository at all.

## How a resource moves between owners

It does not, in normal operation. If it must (for example, adopting something that already exists):

1. Write down the current owner and the intended owner.
2. Render both forms and diff them — `helm template` versus what Argo CD would apply — until the
   diff is empty or every difference is understood.
3. Remove the old owner's claim (uninstall the Helm release, keeping the resources, or delete the
   resources entirely if downtime is acceptable in this lab).
4. Let the new owner create or adopt them.
5. Record it in the session log.

## Consequences

**Good.** Any object can be traced to one file in one repository. Rebuilding a cluster is
reproducible. There are no ownership fights, because there is no shared ownership.

**Costly.** Early modules feel slower: you cannot "just install it to see". That cost is paid once;
the alternative is paid continuously.

**Risk.** Layer 2 is a single point of failure for recovery. Mitigated by keeping the Ansible
bootstrap tested — Module 11 includes destroying Argo CD and rebuilding it from Ansible as a drill,
not as an incident.
