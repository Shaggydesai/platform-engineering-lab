#!/usr/bin/env bash
# kubeadm, kubelet and kubectl - installed and HELD.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${K8S_MINOR:=v1.34}"

install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get -y install kubelet kubeadm kubectl

# Held, so an unattended upgrade cannot move the cluster a minor version overnight.
# Kubernetes version skew rules are strict and upgrades must be deliberate and ordered.
apt-mark hold kubelet kubeadm kubectl
apt-mark showhold

# kubelet is enabled but will crash-loop until kubeadm gives it a configuration. That is
# expected and correct: it is waiting for /etc/kubernetes/kubelet.conf to exist.
systemctl enable kubelet

kubeadm version
kubectl version --client
