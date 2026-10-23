# Runbook: bootstrapping the on-prem cluster by hand

**Owner:** you, this once. Ansible takes it over in Module 03 (Layer 1 in ADR-0002)
**Module:** 02
**Prerequisite:** Module 01's gate passes — three nodes reachable, three distinct machine-ids
**Time:** two sessions. Do not try to finish it in one.

## Why this module is done by hand

Every other module forbids manual work. This one requires it, for one reason: **you cannot
automate a thing you have not watched happen.** Module 03 writes Ansible roles that reproduce
exactly what you do here, and the gate for Module 03 is that its cluster is indistinguishable
from this one. If you have never seen `kubeadm init` print its phases, that Ansible role is
cargo cult — you will copy a role from the internet, it will mostly work, and the first time it
does not you will have no model of what it was supposed to do.

So: type the commands, read the output, and write down what surprised you. The surprises are the
module.

## What you are building

```text
                    k8s-cp01  192.168.100.10   2 vCPU / 4 GB
  ┌──────────────────────────────────────────────────────────────┐
  │  kubelet  (systemd unit, the only non-container component)   │
  │    │ reads /etc/kubernetes/manifests, runs these forever:    │
  │    ├── etcd                 the entire cluster state         │
  │    ├── kube-apiserver       the only thing that talks to it  │
  │    ├── kube-controller-manager                               │
  │    └── kube-scheduler                                        │
  │  then, as ordinary workloads once the API server is up:      │
  │    ├── kube-proxy    (DaemonSet)  Service rules in iptables  │
  │    ├── cilium        (DaemonSet)  pod networking, policy     │
  │    └── coredns       (Deployment) cluster DNS                │
  └──────────────────────────────────────────────────────────────┘
          │                                   │
   k8s-w01 .11  3 vCPU / 8 GB          k8s-w02 .12  3 vCPU / 8 GB
   kubelet + kube-proxy + cilium       kubelet + kube-proxy + cilium
```

Two facts worth holding onto before you start:

**The control plane is just pods.** etcd, the API server, the controller manager and the scheduler
are containers, started by the kubelet from YAML files on disk — "static pods". Nothing schedules
them; they are not in etcd; deleting them from the API does nothing. That is how the cluster
bootstraps itself out of nothing: the kubelet can run pods before there is an API server to ask.

**The kubelet is the only thing installed as a system service.** Everything else is a container.
When a cluster is broken, `systemctl status kubelet` and `journalctl -u kubelet` are almost always
the first two commands, because the kubelet is the only component that can report that it cannot
start the others.

---

## Step 0 — verify what the image already did

The golden image did the boring, error-prone groundwork. Confirm it rather than trusting it: a
wrong answer here produces a `kubeadm init` failure that looks like something else entirely.

```bash
ssh sagar@192.168.100.10
```

```bash
# 1. swap must be off. The kubelet's scheduling and eviction maths assume memory is memory;
#    with swap on, a node lies about pressure and pods get killed for reasons that do not
#    appear in any metric you are looking at.
swapon --show || echo "no swap - correct"
free -h | awk '/Swap/{print}'

# 2. the kernel must forward bridged traffic through iptables, and route between interfaces.
#    Without br_netfilter, Service traffic from a pod to another pod on the same node bypasses
#    the rules kube-proxy wrote, and some connections work while others silently do not.
lsmod | grep -E 'br_netfilter|overlay'
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward

# 3. containerd must use the systemd cgroup driver, matching the kubelet. If they disagree,
#    there are two views of the cgroup hierarchy, and the symptom is pods that start and then
#    get OOM-killed at sizes far below their limits.
sudo containerd config dump | grep -i SystemdCgroup
systemctl is-active containerd

# 4. the versions are pinned and held, so an apt upgrade cannot skew the control plane
kubeadm version -o short; kubelet --version
apt-mark showhold

# 5. the kubelet is enabled and crash-looping. This is CORRECT right now - it has no
#    configuration yet. kubeadm gives it one in step 2.
systemctl is-enabled kubelet; systemctl is-active kubelet || true

# 6. time. etcd and certificate validity both depend on the clock, and a nested VM's clock
#    drifts when the host sleeps - which a laptop does constantly.
timedatectl | grep -E 'synchronized|NTP'

# 7. every node can name every other node, because cloud-init wrote /etc/hosts
getent hosts k8s-cp01.platform.local k8s-w01 k8s-w02

# 8. no host firewall. Kubernetes expects to own the host's packet filtering: kube-proxy
#    and Cilium each write their own rules, and a second firewall with a default-deny
#    policy fights them. It does not fail cleanly either - the cluster appears to work
#    and then loses some traffic depending on which node a pod landed on.
sudo ufw status || echo "ufw not installed - fine"
sudo iptables -S | head -5      # should be the three default ACCEPT policies and nothing else
```

Expect: `SystemdCgroup = true`, both sysctls `= 1`, both modules loaded, no swap, three holds,
kubelet `enabled` but `activating`/`failed`, clock synchronised, all three names resolving, and
ufw `inactive`.

> **If `ufw` reports `active`**, stop and rebuild the image rather than disabling it by hand on
> three nodes: `40-harden.sh` disables it, so an active ufw means the nodes predate that change.
> `make image && make onprem-vms-destroy && make onprem-vms` costs four minutes, and fixing the
> image is the difference between a fix that survives the next rebuild and one that does not.

> **If `timedatectl` says the clock is not synchronised**, fix it before continuing:
> `sudo systemctl restart chrony && sleep 5 && chronyc tracking`. A clock that is minutes out
> produces TLS errors during `kubeadm init` that read as certificate problems.

---

## Step 1 — write the kubeadm configuration file

Most tutorials run `kubeadm init --pod-network-cidr=... --apiserver-advertise-address=...`. We
use a config file instead, for three reasons:

- Flags cover maybe a third of what is configurable; the rest is only reachable this way.
- The file is a **record**. Six months from now, "what did we set and why" is answered by reading
  one file, not by reconstructing a shell command.
- Module 03's Ansible role will template this exact file. Writing it now means the automation is
  a templating exercise rather than a redesign.

**The file lives in Git, at `clusters/onprem/kubeadm/init.yaml`.** From the WSL workstation:

```bash
make onprem-kubeadm-config
```

That copies it to `/etc/kubernetes/kubeadm/init.yaml` on the control plane and then checks four
things there: the CIDRs and node address match `nodes.json`, the pinned `kubernetesVersion` matches
the installed `kubeadm`, the copy's checksum is identical, and all **four** documents arrived.

The last check exists because of a real failure. Pasting this file into an SSH session as a
heredoc truncated when the terminal wrapped — and `kubeadm config validate` said `ok`, because it
validates that the fields *present* are correct and cannot know what you meant to include. A
truncated config that parses is a valid config. The `KubeletConfiguration` block vanished, which
would have taken `resolvConf` with it and produced a CoreDNS loop an hour later, by which point
nobody would connect the two events.

The moral is not "paste more carefully". It is that configuration belongs in a file under version
control, moved by a tool that can verify the move.

The file, annotated — this is what `make onprem-kubeadm-config` sends:

```yaml
# ---------------------------------------------------------------------------
# InitConfiguration: things true of THIS node, only at the moment of init.
# ---------------------------------------------------------------------------
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  # The address the API server binds and advertises. Must be this node's real
  # address, not 0.0.0.0 - it is baked into the certificates and into the
  # kubeconfig files kubeadm generates.
  advertiseAddress: 192.168.100.10
  bindPort: 6443
nodeRegistration:
  name: k8s-cp01
  # Which runtime to talk to. There is exactly one socket on this machine, but
  # being explicit means the error when it is missing says "socket not found"
  # rather than "no runtime detected".
  criSocket: unix:///run/containerd/containerd.sock
  taints:
    # kubeadm applies this taint by default. Written out explicitly so that
    # removing it later (to schedule workloads on the control plane) is a visible
    # edit to a file rather than a forgotten kubectl command. With 11 vCPU of
    # worker capacity we do NOT need to, and a control plane that shares its
    # 4 GB with workloads is a control plane that dies under load.
    - key: node-role.kubernetes.io/control-plane
      effect: NoSchedule
---
# ---------------------------------------------------------------------------
# ClusterConfiguration: things true of the CLUSTER, stored in etcd and reused
# by every future `kubeadm join` and `kubeadm upgrade`.
# ---------------------------------------------------------------------------
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: onprem

# Pin it, and pin it to what is actually installed - `kubeadm version -o short`.
# Left unset, kubeadm chooses for itself, and if it ever chooses a version newer
# than the held kubelet packages you get control-plane images from one release
# running against a kubelet from another. That is supported in one direction only
# (kubelet may trail the control plane, never lead it), and the failure is obscure.
# Pinning also means init makes no network call to resolve a version.
kubernetesVersion: v1.34.12

# controlPlaneEndpoint is the single most consequential line here, and the one
# most tutorials omit. It is the name clients and joining nodes use to reach the
# API server. Omit it and everything hardcodes 192.168.100.10; adding a second
# control plane behind a load balancer later then means regenerating every
# certificate and rewriting every kubeconfig. Set it now, to a NAME, and that
# future change is a DNS change.
#
# It resolves because cloud-init wrote /etc/hosts on every node in Module 01.
controlPlaneEndpoint: "k8s-cp01.platform.local:6443"

networking:
  # Both CIDRs are fixed in ADR-0007 and recorded in clusters/onprem/nodes.json.
  # Neither may overlap 192.168.100.0/24, or a pod trying to reach a node would
  # route to a pod instead - a failure that looks like DNS and is not.
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
  dnsDomain: cluster.local

apiServer:
  # Additional names the API server's certificate is valid for. Without these,
  # `kubectl` via any name other than the advertise address fails TLS
  # verification - and you will reach it by several names.
  certSANs:
    - k8s-cp01
    - k8s-cp01.platform.local
    - 192.168.100.10
    - 127.0.0.1

etcd:
  local:
    dataDir: /var/lib/etcd

---
# ---------------------------------------------------------------------------
# KubeletConfiguration: applies to every node that joins, stored in a ConfigMap
# in kube-system. This is why a joining worker needs no local kubelet config.
# ---------------------------------------------------------------------------
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd

# Ubuntu's /etc/resolv.conf is a symlink to systemd-resolved's STUB file, which
# contains the single nameserver 127.0.0.53 - a local listener. The kubelet hands
# the node's resolv.conf to CoreDNS as its upstream, so CoreDNS would be told to
# forward unresolved queries to a stub on its own node, which forwards them back.
# CoreDNS detects that and refuses to start, with "Loop ... detected".
#
# Point the kubelet at the file holding the REAL upstream servers instead. This is
# the single most common Ubuntu-plus-kubeadm failure, and it presents as DNS being
# broken cluster-wide, which sends people looking at CoreDNS rather than at the host.
resolvConf: /run/systemd/resolve/resolv.conf

# Reserve resources for the OS and for the kubelet itself. Without reservations
# the kubelet will happily schedule pods until sshd gets OOM-killed, and then
# the node is unreachable and you are debugging through the console. On a 4 GB
# control plane this is not a nicety.
systemReserved:
  cpu: "200m"
  memory: "256Mi"
kubeReserved:
  cpu: "200m"
  memory: "256Mi"
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"

# Serial image pulls are the default and they make a three-node rollout crawl.
serializeImagePulls: false

---
# ---------------------------------------------------------------------------
# KubeProxyConfiguration. Present so that Module 04 - which removes kube-proxy
# in favour of Cilium's eBPF datapath - has a before state to compare against.
# ---------------------------------------------------------------------------
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: iptables
```

Then pull the images, on the node:

```bash
sudo kubeadm config images pull --config /etc/kubernetes/kubeadm/init.yaml
```

Pulling the images first separates "the network or registry is a problem" from "the cluster is a
problem". It also makes `init` take about forty seconds instead of three minutes.

> **`v1beta4`** is the config API for Kubernetes 1.31 and later; `v1beta3` is gone in 1.34. If you
> read a tutorial using `v1beta3`, it predates this cluster. One thing v1beta4 changed that bites
> people: `kubeletExtraArgs` is now a list of `{name, value}` objects, not a map.

---

## Step 2 — init, and watch the phases

```bash
sudo kubeadm init --config /etc/kubernetes/kubeadm/init.yaml | tee ~/kubeadm-init.log
```

**Keep that log.** It contains the join command, and reading it afterwards is the exercise.

kubeadm is a sequence of phases, each of which you could run alone (`kubeadm init phase --help`).
In order, with what each one leaves on disk:

| Phase | What it does | Where to look |
|:--|:--|:--|
| `preflight` | the checks you did by hand in step 0, plus ports, plus whether the CRI answers | errors here are refusals to start, not failures |
| `certs` | generates the CA and **nine** certificates: API server, its kubelet client, front-proxy pair, four for etcd, and the service-account signing keypair | `sudo ls /etc/kubernetes/pki/` |
| `kubeconfig` | four kubeconfigs: `admin.conf`, `super-admin.conf`, `kubelet.conf`, `controller-manager.conf`, `scheduler.conf` | `sudo ls /etc/kubernetes/*.conf` |
| `etcd/local` | writes etcd's static pod manifest | `sudo cat /etc/kubernetes/manifests/etcd.yaml` |
| `control-plane` | writes the other three static pod manifests | `/etc/kubernetes/manifests/` |
| `kubelet-start` | writes the kubelet's config and **starts it** — this is the moment the control plane comes alive | `journalctl -u kubelet -f` in another window |
| `upload-config` | stores the two configs you just wrote into ConfigMaps in etcd, so joining nodes read them | `kubectl -n kube-system get cm kubeadm-config kubelet-config` |
| `mark-control-plane` | labels and taints this node | |
| `bootstrap-token` | creates the 24-hour token a worker uses to authenticate before it has a certificate | `kubeadm token list` |
| `kubelet-finalize` | switches the kubelet from its bootstrap cert to a rotatable client cert | `/var/lib/kubelet/pki/` |
| `addon/coredns`, `addon/kube-proxy` | the two things kubeadm installs as real workloads | `kubectl -n kube-system get ds,deploy` |

Two things worth understanding properly:

**`admin.conf` is no longer god.** Since 1.29, `admin.conf` authenticates as a user in the
`kubeadm:cluster-admins` group, which is granted `cluster-admin` by an RBAC binding you can
inspect and change. `super-admin.conf` is the break-glass credential that bypasses RBAC
entirely. Keep `super-admin.conf` where it is, root-owned, and use `admin.conf`. The reason it
matters: if you ever break RBAC, `super-admin.conf` is how you get back in — so do not treat it
as a spare copy of `admin.conf`.

**The bootstrap token is a chicken-and-egg solution.** A joining worker needs to talk to the API
server to get a certificate, but needs a certificate to talk to the API server. The token breaks
the loop: it authenticates the node just well enough to submit a certificate signing request,
which is then auto-approved. It expires in 24 hours by design. When you join a worker next week
and the token has gone, that is not a bug — see step 6.

---

## Step 3 — get a kubeconfig

```bash
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
kubectl config rename-context kubernetes-admin@onprem onprem-admin
kubectl cluster-info
```

Then pull it back to the WSL workstation, which is where you will actually work:

```bash
# from WSL, not from the node
mkdir -p ~/.kube
scp sagar@192.168.100.10:~/.kube/config ~/.kube/config-onprem
KUBECONFIG=~/.kube/config:~/.kube/config-onprem kubectl config view --flatten > /tmp/merged
mv /tmp/merged ~/.kube/config
chmod 600 ~/.kube/config
kubectl config get-contexts
kubectl config use-context onprem-admin
```

That `--flatten` merge keeps your existing GKE context alongside the new one. You now have two
contexts and will eventually have three, which is the point of ADR-0001 — and also the reason
every destructive script in this repo prints the context and asks first.

> **Rename the context.** `kubernetes-admin@onprem` next to
> `gke_shopverse-lab_asia-south1-a_shopverse-lab` is how people run the wrong command against the
> wrong cluster. Your shell prompt already shows the context; make it short enough to read.

---

## Step 4 — look at what you just built, before you fix it

Do not install the CNI yet. The broken state is informative, and you will never see it again.

```bash
kubectl get nodes
# NAME       STATUS     ROLES           AGE   VERSION
# k8s-cp01   NotReady   control-plane   1m    v1.34.x
```

**Why `NotReady`.** Ask the node itself:

```bash
kubectl describe node k8s-cp01 | grep -A3 'Ready '
# ... KubeletNotReady  container runtime network not ready:
#     NetworkReady=false reason:NetworkPluginNotReady message:Network plugin returns error:
#     cni plugin not initialized
```

The kubelet refuses to call itself Ready because there is no CNI plugin in `/etc/cni/net.d`, so
it cannot give a pod an address. kubeadm does not install one on purpose: the CNI choice shapes
NetworkPolicy, Service implementation and ingress, so it is yours to make (ADR-0007), not
kubeadm's to assume.

```bash
kubectl get pods -A
```

CoreDNS is `Pending` — it needs a pod address, so it waits. Everything else is `Running`, because
the static pods use the host network and need no CNI at all. That is the bootstrap order made
visible: host-network components first, then the network, then everything that needs it.

Now look at the pieces:

```bash
# What owns a static pod? Not a Deployment or a DaemonSet - the NODE does.
kubectl -n kube-system get pod kube-apiserver-k8s-cp01 \
  -o jsonpath='{.metadata.ownerReferences}'; echo
# [{"apiVersion":"v1","controller":true,"kind":"Node","name":"k8s-cp01",...}]

kubectl -n kube-system get pod kube-apiserver-k8s-cp01 \
  -o jsonpath='{.metadata.annotations}' | tr ',' '\n' | grep mirror
# "kubernetes.io/config.mirror":"..."

# prove the manifest on disk IS the deployment mechanism
sudo ls -l /etc/kubernetes/manifests/

# etcd holds everything. Talk to it directly, once, so it is not a black box.
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/namespaces/default --print-value-only | head -c 400; echo

# when do the certificates expire? One year. Write the date somewhere.
sudo kubeadm certs check-expiration | head -15
```

> **Certificate expiry is the classic lab killer.** You build a cluster, come back in thirteen
> months, and nothing works for reasons that look like networking. `kubeadm certs renew all`
> fixes it, but only if you know that is the question. In Module 03 the Ansible role will check
> this; for now, note the date in `STATUS.md`.

**That annotation is the whole trick.** A static pod's API object is a *mirror pod*: a read-only
copy the kubelet publishes so that `kubectl get pods` can show you something. It is not the pod.
The real pod is a container the kubelet started from a file, and the API server is reading a
reflection of it — which is how the API server's own pod can appear in the API server.

The ownership is upside-down from everything else in Kubernetes. Normally the desired state lives
in etcd and a controller makes reality match it. Here reality lives on disk and the API object
is downstream of it.

Two experiments, in this order, because the contrast is the lesson:

```bash
# 1. Delete the API object. Nothing happens to the component.
kubectl -n kube-system delete pod kube-scheduler-k8s-cp01
kubectl -n kube-system get pod | grep scheduler     # back within a second, same age-ish
sudo crictl ps | grep scheduler                      # the container never restarted
```

```bash
# 2. Move the file. The component actually stops.
sudo mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/
sleep 20; kubectl -n kube-system get pod | grep scheduler   # gone
sudo mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
sleep 20; kubectl -n kube-system get pod | grep scheduler   # back
```

The first deletes a reflection and the kubelet redraws it. The second changes the thing being
reflected. This is also your recovery path when the API server itself will not start: you cannot
`kubectl` your way out of that, but you can always edit a file.

---

## Step 5 — install Cilium

This is the one `helm install` run by hand in this entire project. ADR-0002 Rule 1 bans manual
installs for Layer 3; the CNI is **Layer 1**, because Argo CD cannot run without a pod network,
so a CNI managed by Argo CD would have to exist before the thing that installs it. Module 03
moves this into an Ansible role. Reasons for the choice: ADR-0007.

From the **WSL workstation**:

```bash
helm repo add cilium https://helm.cilium.io
helm repo update
helm search repo cilium/cilium --versions | head -3   # confirm 1.20.3 is still current
```

```bash
mkdir -p ansible/roles/cilium/files        # Module 03 will use this file as-is
cat > ansible/roles/cilium/files/cilium-values.yaml <<'EOF'
# Cilium values for the on-prem cluster. Pinned deliberately: a CNI that changes
# version on its own is a cluster that changes behaviour on its own.
# Rationale for every choice here: docs/adr/0007-cni-choice.md

ipam:
  # cluster-pool: the Cilium operator carves per-node /24s out of the pod CIDR
  # itself, rather than trusting Node.spec.podCIDR from kube-controller-manager.
  # One component owns address allocation instead of two.
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - 10.244.0.0/16
    clusterPoolIPv4MaskSize: 24      # 254 pods per node, 256 nodes - ample

# VXLAN rather than native routing. Native routing is faster but requires the
# underlay to route pod CIDRs between nodes; libvirt's NAT network will not, and
# GKE and EKS each do something different again. One encapsulation mode that
# behaves identically on all three substrates is worth more here than throughput.
routingMode: tunnel
tunnelProtocol: vxlan

# OFF for now. kube-proxy stays, so that Module 04 can remove it as a deliberate
# before/after exercise rather than as a mystery. See ADR-0007.
kubeProxyReplacement: false

# Tell cilium-agent how to reach the API server DIRECTLY, by name and port,
# instead of through the kubernetes.default ClusterIP. That ClusterIP is
# programmed by kube-proxy - so without this, Cilium depends on kube-proxy to
# start, and when we remove kube-proxy in Module 04 nothing can start at all.
k8sServiceHost: k8s-cp01.platform.local
k8sServicePort: 6443

# One replica: there is one control-plane node, and the default of two would leave
# a pod permanently Pending with an anti-affinity rule you then have to go and read.
operator:
  replicas: 1

# Hubble is the reason this is worth the extra memory: it answers "which packet was
# dropped, by which policy, between which two pods". The UI is a Layer 3 concern and
# arrives via Argo CD in Module 10 - not by hand.
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: false

# Small nodes. Keep the agent honest about what it costs.
resources:
  requests:
    cpu: 100m
    memory: 256Mi
EOF
```

```bash
helm install cilium cilium/cilium \
  --version 1.20.3 \
  --namespace kube-system \
  -f ansible/roles/cilium/files/cilium-values.yaml

kubectl -n kube-system rollout status ds/cilium --timeout=180s
kubectl get nodes          # Ready, within about a minute
kubectl get pods -A        # CoreDNS leaves Pending and starts
```

Then verify properly, not just by looking at `Running`:

```bash
# the CLI is worth having; it tests things kubectl cannot see
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -sL --fail "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" \
  | sudo tar xzvfC - /usr/local/bin

cilium status --wait
cilium config view | grep -E 'routing-mode|tunnel|ipam|kube-proxy'
kubectl get ciliumnode -o wide        # the per-node /24 the operator handed out
```

`cilium connectivity test` exists and is thorough, but it creates about 30 pods and takes ten
minutes on nodes this size. Run it once, at the end, while you make tea — not now.

**Expect `check-log-errors` to fail on a lab cluster, and know why.** That test has two halves:
errors in the current logs, and container restart counts. On a laptop the second half fails
because the nodes have rebooted — WSL shutting down, a Terraform change to a domain, the reboot
test itself — and the check cannot tell "restarted because its node rebooted" from "crashed".
The previous container logs are garbage-collected by then, so it errs toward demanding
investigation, which is the right default for a production cluster and noise here.

Do not wave it away without checking. The counters are only innocent if the *logs* are clean:

```bash
# every restart should have been the node going down, not the container dying
kubectl -n kube-system get pod -l k8s-app=cilium \
  -o custom-columns='POD:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,LASTSTATE:.status.containerStatuses[*].lastState.terminated.reason'

# and nothing should be unhappy right now
cilium status --wait
kubectl -n kube-system logs -l k8s-app=cilium -c cilium-agent --since=10m | grep -iE 'level=(error|warning)' | head

# then reset the counters and re-run ONLY that test. All FOUR workloads - it is easy to
# restart the two DaemonSets and forget that hubble-relay and the operator are Deployments,
# and then the test still fails on the one you missed.
kubectl -n kube-system rollout restart ds/cilium ds/cilium-envoy \
                                       deploy/hubble-relay deploy/cilium-operator
kubectl -n kube-system rollout status ds/cilium --timeout=180s
kubectl -n kube-system rollout status deploy/hubble-relay --timeout=120s
cilium connectivity test --test check-log-errors
```

`LASTSTATE` is the column that settles it. **`Unknown`** is what the kubelet records when it
cannot determine why a container ended — the signature of the machine disappearing underneath
it, which is exactly what a reboot or a `virsh destroy` looks like from inside. A container that
actually failed says `Error`, `OOMKilled` or `Completed`. One word, and it is the difference
between "the node rebooted" and "something is wrong".

If it passes after a restart, the counters were the whole story. If it fails again with the same
pods at zero restarts, something really is crashing and that is a different conversation.

Module 03 gets a clean run for free: a cluster Ansible has just built from destroyed nodes has
no reboot history at all, which is a small argument for that module beyond reproducibility.

---

## Step 6 — join the workers

The join command is in `~/kubeadm-init.log` on the control plane. If the token has expired, or you
simply cannot find it, regenerate rather than hunt:

```bash
# on k8s-cp01
kubeadm token create --print-join-command
```

That prints something of the form:

```text
kubeadm join k8s-cp01.platform.local:6443 --token <t> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

Both halves matter and most people copy them without reading:

- `--token` authenticates **the node to the cluster**.
- `--discovery-token-ca-cert-hash` authenticates **the cluster to the node** — it is a fingerprint
  of the cluster CA, and it is what stops a joining worker from handing its credentials to an
  impostor API server. Skipping it with `--discovery-token-unsafe-skip-ca-verification` is exactly
  as bad as it sounds.

Run it on each worker:

```bash
ssh sagar@192.168.100.11 'sudo kubeadm join k8s-cp01.platform.local:6443 --token <t> \
  --discovery-token-ca-cert-hash sha256:<hash>'
ssh sagar@192.168.100.12 'sudo kubeadm join ... '
```

A worker join is short because almost nothing is local: it fetches the cluster CA, gets the
`kubelet-config` ConfigMap you uploaded in step 2, submits a CSR, gets a signed certificate, and
starts the kubelet. There is no per-node configuration file. That is the payoff of
`upload-config`.

```bash
kubectl get nodes -o wide     # three nodes, all Ready within a minute
kubectl -n kube-system get pod -o wide | grep -E 'cilium|kube-proxy'
```

Both DaemonSets now have three pods, because a DaemonSet means "one per node" and there are
suddenly three nodes. Nobody told them to; that is the controller doing its job.

Finally, label the workers. Kubernetes will not let a kubelet give itself a `node-role` label —
a node that can label itself can label itself into any scheduling decision it likes — so it is
set from the control plane:

```bash
kubectl label node k8s-w01 node-role.kubernetes.io/worker=
kubectl label node k8s-w02 node-role.kubernetes.io/worker=
kubectl get nodes
```

---

## Step 7 — the smoke test

```bash
# from WSL, with the onprem context current
make smoke
```

It checks five things, each of which fails for a different reason, which is why they are separate:

| Check | What it being broken means |
|:--|:--|
| nodes Ready | kubelet or CNI |
| a pod on every node | taints, resources, or image pull |
| pod → pod across nodes | the CNI's inter-node path — VXLAN here |
| cluster DNS | CoreDNS, or the Service that fronts it |
| Service reachable by name | DNS **and** kube-proxy **and** the CNI together |

Then the sixth check, which the module's Definition of Done requires and which the script does
not do for you because it takes two minutes:

```bash
# reboot a worker and watch it come back without help
ssh sagar@192.168.100.11 'sudo reboot'
kubectl get nodes -w          # k8s-w01 NotReady, then Ready. Ctrl-C when it returns.
make smoke                    # still passes
```

A node must rejoin a cluster after a reboot with nobody doing anything, because the kubelet is
enabled and its certificate is on disk. If it does not come back, the usual cause is swap
re-enabling itself or a kubelet unit that was started but never enabled.

**Expect the watch to show nothing.** On a fast VM the reboot completes before Kubernetes
notices it happened: the node never goes `NotReady` and its `AGE` keeps climbing, because the
Node object was never re-registered. That is not the test failing — it is
`--node-monitor-grace-period` doing its job, and it is worth understanding, because it is also
the reason `kubectl get nodes` can show `Ready` for a machine that is already gone.

The timeline the control plane actually runs:

| | |
|:--|:--|
| kubelet renews its Lease | every **10s** |
| no renewal for `--node-monitor-grace-period` | **40s** → node becomes `NotReady` |
| `node.kubernetes.io/not-ready:NoExecute` taint applied | immediately after |
| pods' default `tolerationSeconds` for that taint | **300s** → eviction begins |

So a node is unreachable for nearly **six minutes** before its pods are rescheduled. On a lab
that is a curiosity; on a platform with tenants it is the number you get asked about after an
incident, and it is tunable in neither direction for free — shorten it and a slow node flaps,
lengthen it and outages last longer.

### The harder version, worth ten minutes

A reboot tests the node. Killing a node tests the *cluster*. This is the one experiment in
Module 02 that shows the scheduler reacting to a failure rather than to a request:

```bash
# hard power-off, not a reboot. Note which node hubble-relay is on first.
kubectl -n kube-system get pod -o wide | grep hubble
virsh -c qemu:///system destroy k8s-w01

date; kubectl get nodes -w          # ~40s to NotReady
# leave it. In another window:
kubectl -n kube-system get pod -o wide -w | grep hubble
```

At roughly 40 seconds the node goes `NotReady`. Then **nothing happens for five minutes** — the
pods are still listed as `Running` on a machine that no longer exists, which is the single most
misleading state Kubernetes will ever show you. At about 5m40s the eviction fires and
`hubble-relay` is recreated on `k8s-w02`.

Then bring it back:

```bash
make onprem-vms                     # starts the destroyed domain
kubectl get nodes -w                # Ready within a minute
kubectl -n kube-system get pod -o wide | grep hubble
```

`hubble-relay` **stays on `k8s-w02`**. Kubernetes reschedules on failure and never rebalances on
recovery — nothing moves a running pod. That asymmetry surprises people repeatedly, and it is
why "the cluster recovered" and "the cluster is back how it was" are different claims.

> **A guest reboot is not a host reboot.** The domains are `autostart = false` (Module 01), so
> after `wsl --shutdown` or a laptop restart, nothing comes back on its own: run
> `make onprem-vms`, which is idempotent. That is deliberate — a lab that starts 20 GB of VMs
> behind your back is a lab you resent.

---

## The gate for this module

```bash
make smoke          # all five checks, three nodes
```

plus, by hand, once:

1. A worker reboot rejoins with no intervention.
2. `cilium connectivity test` passes.
3. `docs/runbooks/cluster-bootstrap.md` — this file — has your own notes added where reality
   differed from what is written here.
4. ADR-0007 is accurate: if you changed anything about the CNI setup, the ADR says so.

Module 03 does not start until `make smoke` passes. Module 03's own gate is that Ansible
reproduces this cluster from destroyed nodes with no manual steps, and it cannot be judged
without this one working first.

## How it breaks

| Symptom | Cause | Fix |
|:--|:--|:--|
| `kubeadm init` fails at preflight on port 6443 | a previous init is still running | `sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d ~/.kube` then retry |
| init hangs at "waiting for the kubelet to boot up" | kubelet cannot start the static pods — almost always the cgroup driver | `journalctl -xeu kubelet`; check `SystemdCgroup = true` |
| Nodes `NotReady`, `cni plugin not initialized` | no CNI yet | expected before step 5 |
| CoreDNS stays `Pending` after Cilium is up | nothing schedulable, or Cilium is not actually passing traffic | `cilium status`; `kubectl -n kube-system describe pod <coredns>` |
| CoreDNS `CrashLoopBackOff` with "loop detected" | the node's `/etc/resolv.conf` points at systemd-resolved's stub and CoreDNS forwards to itself | `resolvConf: /run/systemd/resolve/resolv.conf` is already set in the config above to prevent this; if it recurs, check that file exists and has real nameservers |
| kubelet fails with "could not open resolv.conf" | systemd-resolved is not running, so that file does not exist | `systemctl status systemd-resolved`; if it is genuinely unused, remove the `resolvConf` line |
| Join fails: "couldn't validate the identity of the API server" | wrong or stale CA hash | `kubeadm token create --print-join-command` again — do not skip verification |
| Join fails: "token not found" | tokens live 24 hours | same command |
| Pod-to-pod works on one node, not across nodes | VXLAN between nodes — MTU or the UDP port | `cilium status --verbose`; check for drops in `hubble observe` |
| `etcdserver: request timed out`, slow-apply warnings | etcd on a nested, shared disk | expected under load here; if constant, the image is on the HDD and should not be (ADR-0004) |
| Everything stops working after ~1 year | certificates expired | `sudo kubeadm certs renew all` then restart the static pods |
| Node `NotReady` after a laptop sleep | clock skew broke TLS | `sudo chronyc makestep` on each node |

## What to write down when you finish

In `STATUS.md`, three lines: the Kubernetes version, the certificate expiry date, and the one
thing in this runbook that turned out to be wrong. The third one is the most valuable, because it
is the part that only you can know.
