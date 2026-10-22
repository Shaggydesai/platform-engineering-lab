#!/usr/bin/env bash
# Make the node names resolve from the WSL workstation.
#
#   make hosts
#
# Module 01's cloud-init writes /etc/hosts on every NODE, so the nodes can name each other.
# The workstation was never part of that, and it needs to be: the kubeconfig and the Cilium
# values both reach the API server as k8s-cp01.platform.local, because ADR-0002's
# controlPlaneEndpoint is deliberately a NAME - so that putting a load balancer in front of
# a second control plane later is a DNS change rather than a certificate regeneration.
#
# The cost of that choice is this script. It is the right trade, but it is not free, and
# "helm cannot resolve the cluster" is how the bill arrives.
#
# Two things have to be true, and both are handled here:
#
#   1. /etc/hosts carries the node entries.
#   2. WSL stops regenerating /etc/hosts on every start, or (1) is undone silently the next
#      time WSL boots - which is the kind of fix that works until you have forgotten you
#      made it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/clusters/onprem/nodes.json"
MARK_BEGIN="# BEGIN platform-engineering-lab (managed by 'make hosts')"
MARK_END="# END platform-engineering-lab"

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
warn() { printf '    %s%s%s\n' "$c_warn" "$*" "$c_off"; }

domain=$(jq -r '.network.domain' "$CONFIG")

block=$(printf '%s\n' "$MARK_BEGIN"
  jq -r --arg d "$domain" \
    '.nodes[] | "\(.address)\t\(.name) \(.name).\($d)"' "$CONFIG"
  printf '%s\n' "$MARK_END")

step 'Updating /etc/hosts'
# Rewrite the managed block rather than appending to it, so running this twice is a no-op
# and changing nodes.json removes the stale entries instead of leaving two answers for one
# name - which resolves to whichever comes first and is maddening to debug.
tmp=$(mktemp)
sudo sed "/^${MARK_BEGIN//\//\\/}$/,/^${MARK_END}$/d" /etc/hosts > "$tmp"
printf '%s\n' "$block" >> "$tmp"
sudo cp "$tmp" /etc/hosts
rm -f "$tmp"
jq -r '.nodes[] | "    \(.address)  \(.name)"' "$CONFIG"

step 'Checking that WSL will not undo this'
# WSL regenerates /etc/hosts on every start unless told otherwise, which would silently
# delete the block above. /etc/wsl.conf is the per-distribution setting and is preferable
# to .wslconfig on the Windows side: it lives inside the distro, so it is visible from here
# and survives a reinstall of the Windows-side config.
if grep -qE '^\s*generateHosts\s*=\s*false' /etc/wsl.conf 2>/dev/null; then
  ok 'generateHosts = false already set in /etc/wsl.conf'
else
  if ! grep -q '^\[network\]' /etc/wsl.conf 2>/dev/null; then
    printf '\n[network]\n' | sudo tee -a /etc/wsl.conf >/dev/null
  fi
  sudo sed -i '/^\[network\]/a generateHosts = false' /etc/wsl.conf
  ok 'added generateHosts = false to /etc/wsl.conf'
  warn 'This takes effect after: wsl --shutdown  (from PowerShell)'
  warn 'Until then /etc/hosts is correct but WSL would rewrite it on next start.'
fi

step 'Verifying'
for n in $(jq -r '.nodes[].name' "$CONFIG"); do
  addr=$(getent hosts "$n.$domain" | awk '{print $1}')
  [[ -n "$addr" ]] && ok "$n.$domain -> $addr" || warn "$n.$domain does NOT resolve"
done
