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

cd "$SRC"
step 'packer init'
packer init .

step 'packer validate'
packer validate .

step 'packer build  (~3 minutes from Ubuntu'"'"'s cloud image)'
echo
rm -rf output
packer build .

echo
ok "Image: $SRC/output/ubuntu-2404-k8s.qcow2 ($(du -h output/ubuntu-2404-k8s.qcow2 2>/dev/null | cut -f1))"
step 'Next:  make onprem-vms'
