#!/usr/bin/env bash
# Collect everything needed to explain why a libvirt node is not reachable.
#
#   ./scripts/diagnose-node.sh                # all nodes in nodes.json
#   ./scripts/diagnose-node.sh k8s-cp01       # one node
#
# Ordered by the questions that actually matter, cheapest first:
#   1. Does the domain exist and is it running - and is it BURNING CPU or has it given up?
#   2. What format did QEMU open the root disk as? (the raw/qcow2 bug of 2026-10-22)
#   3. Does that disk have a backing file - i.e. is there an OS on it at all?
#   4. Can QEMU read the cloud-init seed? Without it there is no user and no network.
#   5. What did QEMU and libvirt say?
#   6. Is there a network, a bridge, and a lease?
#
# Two lessons from the first real use of this script, both encoded below:
#   - `qemu-img info` on a running domain fails with a write-lock error unless you pass
#     --force-share. The first version of this script did not, so its single most
#     important check printed an error instead of an answer.
#   - The question "what format is this disk?" has two answers: what the FILE is, and what
#     QEMU was TOLD it is. Only the second one is ever wrong, and only QEMU's command line
#     in the domain log knows it. That line is where the bug was actually found.
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

  sub "is it actually executing? (run twice - cpu time must CLIMB)"
  # A booting VM burns CPU. A VM that found nothing bootable sits at ~5s forever. Flat CPU
  # time is not "still booting", it is "gave up" - and it means look at the disk, not the
  # network.
  $V domstats "$n" --vcpu 2>&1 | grep -E 'vcpu.0.time|state' || true

  sub "what format did QEMU OPEN the root disk as? <-- READ THIS FIRST"
  # libvirt defaults a disk with no <driver> element to type="raw". QEMU then hands the
  # guest the qcow2 header as though it were a partition table: the VM boots, finds no
  # bootloader, and stops. Everything downstream - no lease, no ping, no SSH - is a
  # consequence, so checking this first saves chasing three symptoms of one cause.
  if sudo test -r "/var/log/libvirt/qemu/$n.log"; then
    fmt=$(sudo grep -o '"node-name":"libvirt-[0-9]*-format","read-only":[a-z]*,"driver":"[a-z0-9]*"' \
            "/var/log/libvirt/qemu/$n.log" | tail -4)
    if [[ -z "$fmt" ]]; then
      echo "  (no -blockdev format line in the log; libvirt may be using an older syntax)"
    else
      echo "$fmt" | sed 's/^/  /'
      if echo "$fmt" | grep -q '"read-only":false,"driver":"raw"'; then
        echo
        echo "  *** The writable disk was opened as RAW. If the file is qcow2 this is the bug. ***"
        echo "  *** Fix: devices.disks[0].driver = { name = \"qemu\", type = \"qcow2\" }       ***"
      fi
    fi
  fi

  sub "root disk - BACKING FILE IS THE KEY LINE"
  # If 'backing file' is absent, the volume is blank: there is no operating system on it,
  # the VM is sitting at a boot prompt, and nothing will ever answer SSH.
  # --force-share is required while the domain is running; without it QEMU refuses to open
  # the image because the VM holds a write lock, and this check tells you nothing.
  disk=$($V domblklist "$n" 2>/dev/null | awk '/vda/{print $2}')
  echo "  path: ${disk:-<none>}"
  [[ -n "$disk" ]] && sudo qemu-img info --force-share "$disk" 2>&1 | sed 's/^/  /'

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

  sub "serial console - last 30 lines of the recorded boot"
  # This is the thing whose absence made the raw/qcow2 bug take an hour. The console is
  # recorded to a file whether or not anyone was attached, so a boot that failed while
  # you were asleep is still readable.
  clog="/var/log/libvirt/qemu/$n-console.log"
  if sudo test -s "$clog"; then
    sudo tail -30 "$clog" | sed 's/^/  /'
    echo "  --- full log: make onprem-boot-log NODE=$n"
  else
    echo "  $clog is empty or missing."
    echo "  If the domain is running, nothing has reached the serial port - which means"
    echo "  the guest never got as far as GRUB. Check the disk format above."
  fi

  sub "interactive console"
  cport=$(( 12300 + $(jq -r --arg n "$n" '.nodes[]|select(.name==$n)|.address' "$CONFIG" | awk -F. '{print $4}') ))
  if ss -ltn 2>/dev/null | grep -q "127.0.0.1:$cport"; then
    echo "  listening on 127.0.0.1:$cport  ->  make onprem-console NODE=$n"
  else
    echo "  nothing listening on 127.0.0.1:$cport (domain not running?)"
  fi

  sub "reachability from WSL"
  ping -c2 -W2 "$(jq -r --arg n "$n" '.nodes[]|select(.name==$n)|.address' "$CONFIG")" 2>&1 | tail -3 | sed 's/^/  /'
done

hr "next"
cat <<'EOT'
  Read the output in this order:

  1. cpu time FLAT across two runs   -> it is not booting. Go to 2 and 3, ignore the network.
  2. writable disk opened as "raw"   -> QEMU read the qcow2 header as a partition table.
                                        Add driver = { name = "qemu", type = "qcow2" }.
  3. "backing file" missing on vda   -> the volume is blank, no OS. Backing-store bug.
  4. seed not readable by libvirt-qemu -> cloud-init never ran. No user, no network, no SSH.
  5. qemu log shows an error         -> the VM never started properly.
  6. cpu time CLIMBING but no lease  -> it is booting; networking or cloud-init is the problem.
                                        This is the only branch where the network matters.
EOT
