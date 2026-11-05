#!/usr/bin/env bash
# Build the golden image with Packer. Runs entirely in WSL (ADR-0006).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/packer/ubuntu-2404"

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
die()  { printf '%sERROR: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

[[ -e /dev/kvm && -w /dev/kvm ]] \
  || die "/dev/kvm is not writable. Run 'make tools', then open a new login shell."
command -v packer >/dev/null || die "packer not installed - run: make tools"

# --- the SSH key the image is built with
PKRVARS="$SRC/variables.auto.pkrvars.hcl"
KEY="$HOME/.ssh/id_ed25519"
if [[ ! -f "$KEY.pub" ]]; then
  step 'Generating an SSH key'
  ssh-keygen -t ed25519 -N '' -C "sagar@platform-lab" -f "$KEY"
fi
if [[ ! -f "$PKRVARS" ]]; then
  printf 'ssh_public_key = "%s"\n' "$(cat "$KEY.pub")" > "$PKRVARS"
  ok "wrote $PKRVARS"
fi

# --- THE KUBERNETES PINS COME FROM THE CONFIG, NOT FROM THIS SCRIPT AND NOT FROM PACKER
#
# 30-kubernetes.sh REQUIRES K8S_PACKAGE_VERSION and has no default, because a default there was
# the bug: it pinned the apt repository to a minor and then installed "newest in that repo today".
# The laptop's image was baked when v1.34.12 was current and was silently correct ever after;
# AWS ran the same scripts on 2026-11-05 and got v1.34.13, which preflight caught.
#
# Removing that default made THIS script the broken one - it ran `packer build .` with no -var,
# so the next image build would have failed asking for a variable, and nobody would have found
# out until the next rebuild. Hence reading them here, from the same file Ansible's preflight
# asserts against: that is what makes the image and the cluster agree by construction rather
# than by somebody remembering to keep two numbers in step.
CFG="$REPO_ROOT/clusters/onprem/nodes.json"
command -v jq >/dev/null || die "jq not installed - run: make tools"
[[ -r "$CFG" ]] || die "cannot read $CFG"

# -e, not just -r: a MISSING key must fail here rather than yield the string "null" and bake it
# into an image that then installs nothing and fails at `kubeadm init` with an unrelated message.
K8S_PACKAGE_VERSION="$(jq -er '.kubernetes.package_version' "$CFG")" || die \
  "clusters/onprem/nodes.json has no kubernetes.package_version - the exact apt version
  (e.g. 1.34.12-1.1) kubelet, kubeadm and kubectl are installed and held at."
K8S_MINOR="$(jq -er '.kubernetes.minor' "$CFG")" || die \
  "clusters/onprem/nodes.json has no kubernetes.minor - the apt repository the image scripts
  add (e.g. v1.34). It must contain kubernetes.version; make lint checks that."

step "Kubernetes $K8S_PACKAGE_VERSION from the $K8S_MINOR repository"
ok "both read from clusters/onprem/nodes.json, the file preflight asserts against"

# An array rather than a string, so the values are passed as single arguments whatever they hold.
PACKER_VARS=(-var "k8s_package_version=$K8S_PACKAGE_VERSION" -var "k8s_minor=$K8S_MINOR")

cd "$SRC"
step 'packer init'
packer init .

# VALIDATE GETS THEM TOO. Without the vars, `packer validate` fails on the missing variable
# rather than on anything about the template, which reads as a broken template.
step 'packer validate'
packer validate "${PACKER_VARS[@]}" .

step 'packer build  (~3 minutes from Ubuntu'"'"'s cloud image)'
echo
rm -rf output
packer build "${PACKER_VARS[@]}" .

echo
ok "Image: $SRC/output/ubuntu-2404-k8s.qcow2 ($(du -h output/ubuntu-2404-k8s.qcow2 2>/dev/null | cut -f1))"
step 'Next:  make onprem-vms'
