#!/usr/bin/env bash
# Build the golden image with Packer.
#
# Packer's vmware-iso builder drives a LOCAL VMware installation - it runs vmrun and
# vmware-vdiskmanager directly. Inside WSL those Linux binaries do not exist, and VMware
# Workstation is a Windows application, so Packer must run on the Windows side.
#
# Rather than keeping a second copy of the repo on C:, or fighting UNC paths into
# \\wsl.localhost, this syncs the packer directory to a build location on C: and invokes
# packer.exe there. Git stays the source of truth; C:\VMs\build is a disposable artifact.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/packer/ubuntu-2404"
BUILD_WIN='C:\VMs\build\packer\ubuntu-2404'
BUILD_WSL='/mnt/c/VMs/build/packer/ubuntu-2404'

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
die()  { printf '%sERROR: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

grep -qi microsoft /proc/version || die "run this from WSL"

# --- packer.exe must exist on the Windows side, not just in WSL
step 'Checking for packer.exe on Windows'
if ! powershell.exe -NoProfile -Command 'packer version' >/dev/null 2>&1; then
  die "packer.exe not found on Windows.
     The Linux packer in WSL cannot drive VMware Workstation - see ADR-0005.
     Install it on Windows (PowerShell as admin):
       winget install --id HashiCorp.Packer -e
     then reopen this shell and retry."
fi
ok "$(powershell.exe -NoProfile -Command 'packer version' 2>/dev/null | tr -d '\r' | head -1)"

# --- the SSH key Packer injects into the image
PKRVARS="$SRC/variables.auto.pkrvars.hcl"
if [[ ! -f "$PKRVARS" ]]; then
  step 'Creating variables.auto.pkrvars.hcl'
  KEY="$HOME/.ssh/id_ed25519"
  if [[ ! -f "$KEY.pub" ]]; then
    ok 'no SSH key found, generating one'
    ssh-keygen -t ed25519 -N '' -C "sagar@platform-lab" -f "$KEY"
  fi
  printf 'ssh_public_key = "%s"\n' "$(cat "$KEY.pub")" > "$PKRVARS"
  ok "wrote $PKRVARS"
fi
grep -q 'ssh-' "$PKRVARS" || die "no public key in $PKRVARS"

# --- sync to the Windows build directory
step "Syncing to $BUILD_WIN"
mkdir -p "$(dirname "$BUILD_WSL")"
rm -rf "$BUILD_WSL"
mkdir -p "$BUILD_WSL"
cp -a "$SRC/." "$BUILD_WSL/"
# Provisioner scripts run inside the Linux guest: they must keep LF endings even though they
# now live on an NTFS filesystem. cp preserves them; this is a guard against future edits.
if grep -rlq $'\r' "$BUILD_WSL/scripts" 2>/dev/null; then
  die "CRLF found in provisioner scripts - they would fail inside the guest"
fi
ok "$(find "$BUILD_WSL" -type f | wc -l) files"

# --- build
step 'packer init'
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
  "Set-Location '$BUILD_WIN'; packer init ." || die 'packer init failed'

step 'packer build  (about 20 minutes - watch the VMware window)'
echo
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
  "Set-Location '$BUILD_WIN'; packer build ." || die 'packer build failed'

echo
ok 'Image built.'
step 'Next:  make onprem-vms'
