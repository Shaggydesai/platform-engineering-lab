#!/usr/bin/env bash
# kubeadm, kubelet and kubectl - installed and HELD.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${K8S_MINOR:=v1.34}"

# K8S_PACKAGE_VERSION IS REQUIRED, AND THAT IS A CORRECTION RATHER THAN A FEATURE.
#
# This script used to run `apt-get install kubelet kubeadm kubectl` with no version, which pins
# the REPOSITORY to a minor and then takes whatever patch is newest on the day. For a Packer
# image that is a point-in-time artifact: the laptop's image was baked when v1.34.12 was current
# and has run v1.34.12 ever since, so nothing noticed.
#
# Module 09 runs these same scripts at boot on EC2 instead of baking them (ADR-0025), and on
# 2026-11-05 that produced v1.34.13 while the laptop ran v1.34.12 - caught by preflight, which
# asserts the installed kubeadm against clusters/*/kubernetes.version. Same definition, same
# repository, different day, different Kubernetes.
#
# THE LATENT BUG WAS ON-PREM ALL ALONG: re-baking the laptop image next month would silently have
# produced a different patch, with nothing to notice until a rebuilt node refused to join a
# cluster built from the old image. Running the scripts a second way is what exposed it.
#
# So the version is named, not discovered. No default: a default here is the bug.
if [ -z "${K8S_PACKAGE_VERSION:-}" ]; then
  echo "K8S_PACKAGE_VERSION is required, e.g. 1.34.12-1.1" >&2
  echo "It is kubernetes.package_version in clusters/<substrate>/*.json." >&2
  echo "Available: apt-cache madison kubeadm" >&2
  exit 1
fi

install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update

# EXACT VERSIONS, and all three together. Installing kubeadm pinned while kubelet floats is worse
# than not pinning at all: the skew is then invisible in `kubeadm version`, which is the one thing
# preflight reads.
apt-get -y install \
  "kubelet=${K8S_PACKAGE_VERSION}" \
  "kubeadm=${K8S_PACKAGE_VERSION}" \
  "kubectl=${K8S_PACKAGE_VERSION}"

# Held, so an unattended upgrade cannot move the cluster a minor version overnight.
# Kubernetes version skew rules are strict and upgrades must be deliberate and ordered.
apt-mark hold kubelet kubeadm kubectl
apt-mark showhold

# kubelet is enabled but will crash-loop until kubeadm gives it a configuration. That is
# expected and correct: it is waiting for /etc/kubernetes/kubelet.conf to exist.
systemctl enable kubelet

kubeadm version
kubectl version --client
