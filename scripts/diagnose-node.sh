#!/usr/bin/env bash
# Collect everything needed to explain why a libvirt node is not reachable.
#
#   ./scripts/diagnose-node.sh                # all nodes in nodes.json
#   ./scripts/diagnose-node.sh k8s-cp01       # one node
#
# Ordered by the questions that actually matter, cheapest first:
#   1. Does the domain exist and is it running?
#   2. Does its disk have a backing file - i.e. is there an OS on it at all?
#   3. Can QEMU read the cloud-init seed? Without it there is no user and no network.
#   4. What did QEMU and libvirt say?
#   5. Is there a network, a bridge, and a lease?
#   6. What is on the screen right now?
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/clusters/onprem/nodes.json"
V="virsh -c qemu:///system"

hr()  { printf '\n\033[36m─── %s %s\033[0m\n' "$*" "$(printf '─%.0s' $(seq 1 $((60 - ${#1}))))"; }
sub() { printf '\033[33m• %s\033[0m\n' "$*"; }

nodes=("$@")
if [[ ${#nodes[@]} -eq 0 ]]; then
  mapfile -t nodes < <(jq -r '.nodes[].name' "$CONFIG")
fi

hr "host"
sub "libvirt version";      $V version 2>&1 | head -3
sub "networks";             $V net-list --all 2>&1
sub "bridges with our subnet"
ip -br addr | grep -E '192\.168\.(100|122)\.' || echo "  none - the platform network has no bridge on this host"
sub "storage pool";         $V pool-info default 2>&1 | head -6
sub "free memory";          free -h | head -2

for n in "${nodes[@]}"; do
  hr "$n"

  sub "domain state"
  $V dominfo "$n" 2>&1 | grep -E 'State|CPU|Used memory|Autostart' || echo "  domain not found"

  sub "is it actually executing? (cpu time should climb between runs)"
  $V domstats "$n" --vcpu 2>&1 | grep -E 'vcpu.0.time|state' || true

  sub "root disk - BACKING FILE IS THE KEY LINE"
  # If 'backing file' is absent, the volume is blank: there is no operating system on it,
  # the VM is sitting at a boot prompt, and nothing will ever answer SSH.
  disk=$($V domblklist "$n" 2>/dev/null | awk '/vda/{print $2}')
  echo "  path: ${disk:-<none>}"
  [[ -n "$disk" ]] && sudo qemu-img info "$disk" 2>&1 | sed 's/^/  /'

  sub "cloud-init seed - QEMU MUST BE ABLE TO READ THIS"
  # No readable seed means no user, no SSH key and no network config, so no SSH - even
  # though the VM boots perfectly well.
  seed=$($V domblklist "$n" 2>/dev/null | awk '/vdb/{print $2}')
  echo "  path: ${seed:-<none>}"
  if [[ -n "$seed" ]]; then
    sudo ls -l "$seed" 2>&1 | sed 's/^/  /'
    sudo -u libvirt-qemu test -r "$seed" \
      && echo "  readable by libvirt-qemu: yes" \
      || echo "  readable by libvirt-qemu: NO  <-- this would explain everything"
    sudo file "$seed" 2>&1 | sed 's/^/  /'
    sudo isoinfo -d -i "$seed" 2>/dev/null | grep -i 'volume id' | sed 's/^/  /' \
      || echo "  (isoinfo unavailable; label should be 'cidata')"
  fi

  sub "interface and lease"
  $V domiflist "$n" 2>&1 | sed 's/^/  /'
  $V domifaddr "$n" --source lease 2>&1 | sed 's/^/  /'
  $V domifaddr "$n" --source agent 2>&1 | sed 's/^/  /'

  sub "qemu log (last 25 lines)"
  sudo tail -25 "/var/log/libvirt/qemu/$n.log" 2>&1 | sed 's/^/  /'

  sub "console screenshot"
  if $V screenshot "$n" "/tmp/$n.ppm" >/dev/null 2>&1; then
    if command -v convert >/dev/null 2>&1; then
      convert "/tmp/$n.ppm" "/tmp/$n.png" 2>/dev/null && echo "  /tmp/$n.png"
    else
      echo "  /tmp/$n.ppm  (install imagemagick to convert: sudo apt install -y imagemagick)"
    fi
  else
    echo "  screenshot unavailable (no graphics device configured on this domain)"
  fi

  sub "reachability from WSL"
  ping -c2 -W2 "$(jq -r --arg n "$n" '.nodes[]|select(.name==$n)|.address' "$CONFIG")" 2>&1 | tail -3 | sed 's/^/  /'
done

hr "next"
cat <<'EOT'
  Read the output in this order:

  1. "backing file" missing on vda  -> the node disk is blank, no OS. Volume/backing-store bug.
  2. seed not readable by libvirt-qemu -> cloud-init never ran. No user, no network, no SSH.
  3. qemu log shows an error        -> the VM never started properly.
  4. domain running, cpu time climbing, no lease -> it booted but networking did not come up.
EOT
