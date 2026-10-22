#!/usr/bin/env bash
# Base packages and the tools you will actually use when a node misbehaves.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y upgrade
apt-get -y install \
  vim git jq tree htop tmux rsync unzip \
  net-tools iproute2 iputils-ping dnsutils tcpdump traceroute socat conntrack ethtool \
  lvm2 nfs-common open-iscsi \
  bash-completion chrony

# Time. A VM on a laptop gets suspended; clock skew breaks TLS everywhere and produces
# "certificate is not yet valid" errors that look like a PKI problem and are not.
systemctl enable --now chrony
timedatectl set-timezone UTC

# open-iscsi and nfs-common are here for Longhorn in a later module - installing them in the
# image avoids a reboot on every node later.
systemctl enable --now iscsid || true

# qemu-guest-agent lets libvirt report the guest's address and shut it down cleanly.
apt-get -y install qemu-guest-agent
systemctl enable qemu-guest-agent

# Swap off, permanently. kubelet refuses to start with swap enabled unless explicitly told to.
swapoff -a
sed -i.bak -E '/\sswap\s|swap\.img/s/^/#/' /etc/fstab
