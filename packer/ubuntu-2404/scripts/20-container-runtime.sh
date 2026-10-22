#!/usr/bin/env bash
# containerd, configured the way Kubernetes needs it.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# Kernel modules. overlay backs the container filesystem; br_netfilter makes bridged traffic
# visible to iptables, which is what Service networking depends on.
cat > /etc/modules-load.d/k8s.conf <<'MODS'
overlay
br_netfilter
MODS
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/99-kubernetes.conf <<'SYSCTL'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL
sysctl --system

apt-get update
apt-get -y install containerd

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# The single most common Kubernetes installation bug: kubelet and containerd must agree on the
# cgroup driver. systemd owns the cgroup tree on Ubuntu, so containerd must use it too.
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd
