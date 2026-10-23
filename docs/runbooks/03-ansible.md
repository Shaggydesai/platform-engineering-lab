# Runbook: the bootstrap layer

**Owner:** Ansible — Layer 1 of ADR-0002, bounded by ADR-0008
**Module:** 03
**Prerequisite:** Module 02 closed — a cluster built by hand, and understood

## What this does

Everything Module 02 did by hand, as code, in the same order and for the same reasons.

```text
make onprem-vms        Terraform   three machines from the golden image      (Module 01)
make onprem-up         Ansible     those machines become a cluster           (this module)
make smoke                         five checks against what was built        (Module 02)
```

```text
ansible/
  ansible.cfg                     paths here are relative to THIS FILE, not to your shell
  inventory/nodes.py              the inventory, GENERATED from clusters/onprem/nodes.json
  playbooks/cluster.yml           the one playbook
  playbooks/reset.yml             tear down the cluster, keep the machines
  roles/
    preflight/                    assert the image did its job. Changes nothing.
    control_plane/                kubeadm init, from a template rendered out of nodes.json
    cilium/                       helm upgrade --install, from the values file in Git
    workers/                      kubeadm join, then label
```

## Why it is built this way

**The inventory is generated, not maintained.** `ansible/inventory/nodes.py` reads the same
`clusters/onprem/nodes.json` that Terraform reads. An inventory nobody maintains cannot describe
a cluster that does not exist, which is the most common way an Ansible repository rots. Change a
node's address in one place and both tools see it.

**Ansible asserts the image rather than repeating it** (ADR-0008). Packer owns swap, kernel
modules, sysctls, containerd and the packages. A setting defined in two places has no owner. The
`preflight` role therefore only checks — and every assertion carries the sentence explaining what
breaks when it is false, so a failure says "rebuild the image, here is why" instead of
"assertion failed".

That makes every `onprem-up` a regression test on the image, which has already earned its keep
once: Module 02's step 0 was the human version of this list, and two of its eight checks had
found real problems.

**Idempotency is gated on single files, not on `--force`.** `kubeadm init` fails on an
initialised node and `kubeadm join` fails on a joined one, and the tempting fix — `kubeadm reset`
first — would destroy etcd on every run. So:

| Role | Gate | Why that file |
|:--|:--|:--|
| `control_plane` | `/etc/kubernetes/admin.conf` | exists if and only if init completed |
| `workers` | `/etc/kubernetes/kubelet.conf` | exists if and only if the node joined |
| `cilium` | `helm list` output | `helm upgrade --install` always reports *changed*, which would make a second run look like work |

**Secrets are never logged.** The join token and the printed join command are live credentials,
so those two tasks carry `no_log: true`. Ansible output ends up in scrollback and CI logs.

## Run it

```bash
make onprem-ping            # can Ansible reach all three?
make onprem-inventory       # what did it derive from nodes.json?
make onprem-preflight       # assert the image. Changes nothing, fails loudly.
make onprem-up              # build the cluster
make smoke
```

`make onprem-check` dry-runs the whole playbook. It is less useful than it sounds here — a
`--check` run cannot see the result of a command it did not execute, so it will report that it
*would* initialise an already-initialised cluster. Use it to review the rendered config diff, not
as a safety net.

## The gate for this module — **passed 2026-10-23**

Cluster rebuilt from destroyed machines in about four minutes with no manual steps; the second
run reported `changed=0` on all three hosts.

**Three bugs, each findable by exactly one of the three tests.** This is the part worth keeping:

| Test | Bug it found | Why nothing else would |
|:--|:--|:--|
| `--syntax-check` | paths in `ansible.cfg` resolve against that file's directory, not the shell's | the only symptom is "No inventory was parsed" and then a misleading "role not found" |
| Run twice on a live cluster | a task renamed the file `fetch` uses as its idempotency marker, so `fetch` re-downloaded forever | the first run looks fine; you need a second one to see it |
| Destroy and rebuild | `template` does not create `/etc/kubernetes/kubeadm`, which existed only because Module 02 made it by hand | it passed every run against the live cluster, including the ones reporting `changed=0` |

**Idempotency proves the gates work. Only a rebuild proves the roles are complete.** A cluster
you have fixed by hand quietly supplies the things your automation forgot, and it will keep
supplying them until the day you need to rebuild — which is the day you least want to be
debugging.



```bash
# 1. from nothing
make onprem-vms-destroy
make onprem-vms
make onprem-up
make smoke

# 2. the part that actually matters
make onprem-up
```

**The second run must report `changed=0`.** A task that reports *changed* on an unchanged cluster
is a task that does not know what it already did, and that is the difference between automation
and a script that happens to work. Fix it rather than living with it.

A faster loop while developing the roles, which skips rebuilding the VMs:

```bash
make onprem-down      # cluster gone, machines standing
make onprem-up
```

That is a weaker test than the full gate — a machine that has hosted a cluster is not quite a
fresh one, and the difference is where bugs hide — so the full gate is the one that closes the
module.

## How it breaks

| Symptom | Cause | Fix |
|:--|:--|:--|
| `No inventory was parsed, only implicit localhost` then `role not found` | paths in `ansible.cfg` are relative to that file's directory, not your shell's | they already are; check you did not add a path prefixed with `ansible/` |
| `preflight` fails on the cgroup driver, swap, modules or holds | the image is wrong or stale | `make image`, then destroy and rebuild the nodes. Do **not** fix it on the node — it will be wrong again after the next rebuild |
| `preflight` fails on name resolution | cloud-init's `/etc/hosts` did not land | check the `user-data` template; `make onprem-vms-destroy && make onprem-vms` |
| `preflight` fails on kubeadm version | `nodes.json` `kubernetes.version` and the image's `K8S_MINOR` disagree | make them agree, then rebuild whichever is wrong |
| `kubeadm init` times out waiting for the kubelet | almost always the cgroup driver, which preflight should have caught first | `journalctl -xeu kubelet` on the node |
| Join fails: `couldn't validate the identity of the API server` | stale CA hash — the control plane was rebuilt | the role mints a fresh token every time, so this means the control plane changed mid-run. Re-run |
| `kubectl` fails TLS verification after a rebuild | the merged context holds the old cluster's CA | `make onprem-up` replaces it; that is what the merge task is for |
| Second run reports `changed` | a non-idempotent task | find it in the output. This is a bug in the role, not a quirk |

## What this module buys beyond reproducibility

`cilium connectivity test` has a `check-log-errors` scenario that asserts no component has
restarted. On the Module 02 cluster that failed, because the host slept, Terraform rebooted
domains, and we rebooted a worker deliberately — and establishing that the failure was innocent
took reading `LASTSTATE`, grepping logs, resetting counters and re-running.

A cluster this playbook has just built has no reboot history. So `check-log-errors` becomes a
check whose failure *means* something. Tests that assume a clean start are only worth having if a
clean start is cheap, and this module is what makes it cheap.
