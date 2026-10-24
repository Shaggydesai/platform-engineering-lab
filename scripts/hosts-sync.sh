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
#   3. ~/.ssh/known_hosts does not still hold host keys from a previous generation of these
#      VMs. Every `terraform destroy` + rebuild gives the nodes brand new host keys, and
#      OpenSSH then refuses to connect and prints a man-in-the-middle warning - correctly,
#      because from its point of view that is indistinguishable from an attack.
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

step 'Reconciling SSH host keys'
# Not a blanket "trust whatever answers". This compares the key the node PRESENTS against the
# key we have STORED, and only removes the stored one when they genuinely differ - so a real
# man-in-the-middle warning on some other host still means something.
#
# These particular nodes earn the exception: they are built from a golden image that has its
# host keys stripped (Module 01 seals machine-id and host keys precisely so each rebuild
# generates its own), so for them a changed host key is expected after every rebuild and the
# warning carries no information. On anything with a lifetime longer than an afternoon, this
# is the wrong behaviour.
KNOWN="$HOME/.ssh/known_hosts"
if [[ ! -f "$KNOWN" ]]; then
  ok 'no known_hosts file yet, nothing to reconcile'
else
  for host in $(jq -r --arg d "$domain" '.nodes[] | .address, .name, (.name + "." + $d)' "$CONFIG"); do
    stored=$(ssh-keygen -F "$host" -f "$KNOWN" 2>/dev/null | grep -v '^#' | awk '{print $3}')
    [[ -z "$stored" ]] && continue

    live=$(ssh-keyscan -T 3 "$host" 2>/dev/null | grep -v '^#' || true)
    if [[ -z "$live" ]]; then
      warn "$host did not answer; leaving its stored key alone"
      continue
    fi

    match=no
    while read -r _h _t blob _rest; do
      [[ -n "${blob:-}" ]] && grep -qxF "$blob" <<<"$stored" && match=yes
    done <<<"$live"

    if [[ $match == yes ]]; then
      ok "$host host key unchanged"
    else
      warn "$host presents a new host key - rebuilt since last contact, replacing the entry"
      ssh-keygen -q -f "$KNOWN" -R "$host" >/dev/null 2>&1 || true
      printf '%s\n' "$live" >> "$KNOWN"
      ok "$host host key replaced"
    fi
  done
fi

step 'Verifying'
for n in $(jq -r '.nodes[].name' "$CONFIG"); do
  addr=$(getent hosts "$n.$domain" | awk '{print $1}')
  [[ -n "$addr" ]] && ok "$n.$domain -> $addr" || warn "$n.$domain does NOT resolve"
done
