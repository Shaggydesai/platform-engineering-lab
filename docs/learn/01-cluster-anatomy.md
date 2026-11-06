# 01 — What a Kubernetes cluster is made of

> Read this one first. Everything else in the lab assumes you can name the processes involved and
> say which one is lying when something does not work.

---

## 1. The problem

You have three machines and you want to run containers on them. Not once — continuously, surviving
reboots, with something deciding *where* each container runs and rescheduling it when a machine
dies. Write down what that requires and you have essentially derived Kubernetes:

- **Somewhere to keep the desired state.** "There should be three copies of this container." That
  statement has to survive a reboot of whatever machine you typed it into, so it needs a
  replicated, consistent store.
- **Something to answer questions about that state** and accept changes to it, with authentication,
  validation and some way to watch for changes rather than poll.
- **Something to decide placement.** Three copies, five machines: which three? With what account
  taken of memory, labels, taints?
- **Something on each machine that actually starts containers** and keeps restarting them, and
  reports back what is really running — which is not always what was asked for.
- **Something to give containers addresses** and make them reachable by name.

Those five are, respectively, etcd, the API server, the scheduler, the kubelet, and the CNI plus
DNS. Everything else — controllers, operators, Argo CD, the whole platform layer this lab builds —
is built on top of that and could in principle be written by you.

The thing worth internalising early: **Kubernetes is a database with a reconciliation habit.** You
write a desired state into it; a crowd of controllers each watch the bit they care about and work to
make reality match. Nothing in the system "runs" your deployment. A controller notices the gap.

---

## 2. The mechanism

### 2.1 The control plane

Four processes, and in a kubeadm cluster all but one are containers.

**etcd** is the store. A consistent, distributed key-value store using Raft, and the only
*stateful* component — everything else can be deleted and recreated without loss. It holds every
object in the cluster, serialised, under keys like `/registry/pods/default/nginx`. Two consequences
follow and both matter:

- **An odd number of members, and a majority must be alive.** One member tolerates no failures.
  Three tolerate one. This lab runs one, deliberately (ADR-0004) — so the control plane is a single
  point of failure, which is why Module 11 is about exactly that, and why
  `make ingress-failover-check` refuses to power off the control-plane node.
- **Whatever is in etcd is the cluster.** Back up etcd and you have backed up everything except
  the contents of persistent volumes. This lab has no etcd backup yet; it is in the parking lot,
  and it is the sharpest open item in the repository.

**kube-apiserver** is the only thing that talks to etcd. Everything else — kubectl, the kubelet,
every controller, Argo CD — talks to the API server over HTTPS, and it does the authentication,
the admission control, the validation, and the serialisation. It is stateless: run three of them
behind a load balancer and they are interchangeable.

Two API-server behaviours do more work than they appear to:

- **Watches.** A client can ask for "all pods, and then tell me about changes". This is the
  mechanism controllers are built on, and it is why Kubernetes scales better than its polling
  reputation suggests.
- **Resource versions.** Every object carries one, and an update can be conditional on it. That is
  how two controllers writing the same object do not silently clobber one another.

**kube-scheduler** watches for pods with no `spec.nodeName` and assigns one. That is its entire
job: it writes a node name into a pod. It does not start anything. Filtering (which nodes *could*
run this: enough memory, tolerations matching taints, affinity satisfied) then scoring (which is
*best*). Then a write.

**kube-controller-manager** is many controllers in one binary — Deployment, ReplicaSet, Node,
ServiceAccount, and about thirty more. Each runs the same loop: observe desired state, observe
actual state, act on the difference. When a Deployment says 3 and two pods exist, a controller
creates one. The loop is the whole idea, and when you later meet Argo CD doing the same thing for
Git, it will not be a new concept.

### 2.2 On every node

**kubelet** is the only component that is a normal systemd service rather than a container — it
has to be, because it is what starts containers. It:

- watches the API server for pods assigned to *its* node,
- tells the container runtime to start them,
- runs liveness and readiness probes,
- reports node and pod status back,
- and mounts volumes.

**The container runtime** actually runs containers. The kubelet speaks **CRI** (Container Runtime
Interface) to it over a Unix socket — in this lab `unix:///run/containerd/containerd.sock`, which
you can see in the kubeadm config below. containerd then uses **runc** to create the Linux
namespaces and cgroups that *are* the container. "Container" is not a kernel object; it is a
process with its own view of the filesystem, network and process tree, and a cgroup limiting what
it can consume.

**The CNI plugin** gives each pod its network namespace and address. The kubelet does not do
networking: it calls a binary in `/opt/cni/bin` and expects an address back. In this lab that is
Cilium, and chapter 04 is entirely about what it does.

**kube-proxy** would normally be here, programming iptables so that Service addresses work. **This
lab does not run it at all** — see §3.3.

### 2.3 Static pods: how the control plane starts before the control plane exists

A chicken-and-egg problem: the API server runs as a pod, but pods are created by talking to the API
server. Resolved with **static pods** — the kubelet watches a directory on disk
(`/etc/kubernetes/manifests/`) and runs whatever pod manifests it finds there, with no API server
involved at all.

So on this lab's control plane, `/etc/kubernetes/manifests/` contains four files:
`kube-apiserver.yaml`, `etcd.yaml`, `kube-controller-manager.yaml`, `kube-scheduler.yaml`. The
kubelet starts them because they are files. Once the API server is up, it *also* reports them as
pods (mirror pods) so `kubectl get pods -n kube-system` shows them — but deleting those pods
achieves nothing. The file is the authority.

This is directly useful: **to change an API server flag you edit a file on the node**, and the
kubelet restarts it within seconds. It is also how this lab turns on encryption at rest — the
`etcd_encryption` role regenerates that manifest, and its own task name says what to watch for:
*"Did the manifest actually change?"*

---

## 3. In this lab

### 3.1 What `kubeadm init` writes

`kubeadm` is not a daemon. It runs once, does the work of setting up a control plane, and exits —
which is why this project could do it by hand in Module 03 before letting Ansible do it. Its phases
map onto files:

| Phase | What lands on disk |
|:--|:--|
| `preflight` | nothing — it checks, and it is the phase this lab replaced with its own `preflight` role |
| `certs` | `/etc/kubernetes/pki/` — the CA, and a leaf certificate and key per component |
| `kubeconfig` | `/etc/kubernetes/{admin,kubelet,controller-manager,scheduler}.conf` |
| `control-plane` | `/etc/kubernetes/manifests/*.yaml` — the four static pods |
| `etcd` | `/etc/kubernetes/manifests/etcd.yaml`, data in `/var/lib/etcd` |
| `upload-config` | the `kubeadm-config` ConfigMap, **in the cluster** — so upgrades know how this cluster was built |
| `bootstrap-token` | a token a worker can use to join, valid 24h by default |
| `addons` | CoreDNS, and kube-proxy — except here, see below |

That `upload-config` phase is why this lab's `etcd_encryption` role ends with *"Store the kubeadm
config in the cluster so upgrades keep the flag"*. An upgrade re-renders the static pod manifests
from that ConfigMap; a flag that exists only in the file on disk is a flag the next upgrade
silently removes.

### 3.2 The configuration this lab actually uses

From `ansible/roles/control_plane/templates/kubeadm-init.yaml.j2`, with the parts worth explaining:

```yaml
nodeRegistration:
  name: {{ inventory_hostname }}          # the node's name in the cluster, FOREVER
  criSocket: unix:///run/containerd/containerd.sock
  taints:
    - key: node-role.kubernetes.io/control-plane
      effect: NoSchedule                  # no tenant workload here
```

`name` is load-bearing and is the subject of a mistake recorded in chapter 12: a node registers
under its **hostname**, and EC2 names hosts after their address — so without declaring this, the
cluster would have contained a node called `ip-10-20-1-10` permanently.

```yaml
controlPlaneEndpoint: "{{ control_plane_endpoint }}"
networking:
  podSubnet: 10.244.0.0/16                # addresses for pods
  serviceSubnet: 10.96.0.0/12             # virtual addresses for Services
  dnsDomain: cluster.local
```

Two address ranges, and they are different kinds of thing. A **pod** address is real: something
holds it, you can ping it, the CNI routes to it. A **Service** address is **virtual** — no network
interface anywhere has it, nothing answers ARP for it, and it exists only as a translation rule.
Chapter 04 is about where that translation happens.

`controlPlaneEndpoint` is the address workers join through and the one written into every generated
kubeconfig. On this lab's cloud substrate it is deliberately the control plane's **private**
address, which produced four separate bugs in one afternoon because the kubeconfig a cluster hands
you then names an address your laptop cannot reach. Chapter 12 tells that story.

```yaml
proxy:
  disabled: true
```

**kube-proxy is never installed.** Not installed and then removed — never installed. This is why
`make netpol-check` reports `KUBE-SVC iptables rules 0 -> 0`: there were none to begin with. The
`kube_proxy_removal` role still exists and is idempotent cleanup for a cluster built before this
setting, and it reports `ok` rather than `changed` on every run here.

```yaml
systemReserved: {cpu: "200m", memory: "256Mi"}
kubeReserved:   {cpu: "200m", memory: "256Mi"}
evictionHard:   {memory.available: "200Mi", nodefs.available: "10%"}
```

**Allocatable is not total.** A node's memory is divided: some for the OS, some for the kubelet and
runtime, a hard eviction threshold, and what remains is schedulable. The `preflight` role prints
the arithmetic on every run precisely so this is never a surprise:

```
aws-cp01 (control-plane): 7732 MB total, 7220 MB allocatable after the 512 MB
    reserved for the OS and the kubelet.
```

512 = 256 `systemReserved` + 256 `kubeReserved`. Get this wrong on a small node and you do not get
an error — you get a node that schedules work until the kernel OOM-kills something, which looks
like an application bug.

### 3.3 What `preflight` asserts, and why each one exists

This lab replaced kubeadm's preflight checks with its own Ansible role, and every assertion is
there because its absence produces a confusing failure rather than a clear one:

| Assertion | Without it |
|:--|:--|
| **swap is off** | the kubelet's memory accounting is meaningless; a pod "within its limit" can be paging. Kubernetes refused to start with swap on for years for this reason. |
| **`br_netfilter` and `overlay` loaded** | bridged traffic bypasses iptables, so Service rules silently do not apply to some paths |
| **`bridge-nf-call-iptables=1`, `ip_forward=1`** | the node will not forward packets between interfaces, so pod-to-pod across nodes fails |
| **containerd `SystemdCgroup = true`** | two cgroup managers — the kubelet and containerd — disagree about who owns a cgroup, producing eviction behaviour that makes no sense |
| **three packages held at an exact version** | see below; this one caught a real bug |
| **no host firewall active** | ufw or firewalld silently drops the ports the cluster needs |
| **clock synchronised** | certificate validation and etcd's Raft both fail in ways that do not mention clocks |
| **every node resolves every other by name** | `controlPlaneEndpoint` may be a name, and a worker that cannot resolve it cannot join |

Run it yourself:

```
make onprem-cluster          # the whole playbook; preflight is the first play
```

### 3.4 Seeing all of it

```bash
# the static pods, as files
ssh k8s-cp01 'ls /etc/kubernetes/manifests/'

# the same four, as the API server reports them
kubectl -n kube-system get pods -l tier=control-plane

# what the kubelet is, unlike everything above
ssh k8s-cp01 'systemctl status kubelet --no-pager | head -5'

# which runtime, and which version of it
kubectl get nodes -o wide
```

That last one is where you see `containerd://2.2.1` and `v1.34.12` side by side — the runtime
version and the Kubernetes version are independent, and only one of them is pinned by this lab's
config.

---

## 4. What bit us

**The version pin that was not a pin.** `30-kubernetes.sh` added the Kubernetes apt repository for
a *minor* version (`v1.34`) and then ran `apt-get install kubelet kubeadm kubectl` with no version
— which installs "the newest in that repository today". The laptop's image was baked when v1.34.12
was current and was silently correct for weeks. The same scripts ran on EC2 on 2026-11-05 and
installed **v1.34.13**, and `preflight` caught it because it asserts an exact version rather than a
range.

The lesson is not about apt. It is that **a definition which produces different output on different
days is not a definition**, and the only thing that exposed it was delivering the same scripts a
second way. `K8S_PACKAGE_VERSION` is now required with no default, which immediately broke
`scripts/build-image.sh` for passing no value — one bug revealing the next.

**The kubeconfig that names an unreachable address.** `kubeadm` writes `controlPlaneEndpoint` into
`admin.conf`. On AWS that is the private address by deliberate choice, so four roles and one
playbook that ran `kubectl` on the workstation with that kubeconfig all failed with
`dial tcp 10.20.1.10:6443: i/o timeout` — a network error, from a working cluster. Fixed four
separate times in one afternoon because each fix was applied to the files in front of me rather
than to the rule; `make lint` now enforces that only one role may name the fetched file.

**The node that would have been called `ip-10-20-1-10`.** EC2 names a host after its address and
kubeadm registers a node under its hostname, so `nodeRegistration.name` is the difference between a
cluster of `aws-cp01`/`aws-w01`/`aws-w02` and one named after addresses that change every session.
On-prem this is free — the libvirt seed sets the hostname — which is exactly why it was not noticed
until the second substrate.

---

## Next

Chapter 04 — [Pod networking, eBPF, and life without kube-proxy](04-pod-networking.md) — picks up
the two address ranges from §3.2 and follows a packet through them.

Primary sources for this chapter, when you want the reference rather than the explanation:
`docs/reading.md`, rows ADR-0001/0002 and the kubeadm row.
