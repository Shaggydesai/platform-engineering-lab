#!/usr/bin/env bash
# Attach to a node's serial console, or tail its recorded boot log.
#
#   ./scripts/console.sh k8s-cp01          interactive console
#   ./scripts/console.sh k8s-cp01 --log    the recorded boot log, followed
#   ./scripts/console.sh k8s-cp01 --last   the last boot only, from the log
#
# The console is a raw TCP chardev bound to 127.0.0.1 by libvirt (see terraform/onprem/
# main.tf). It is NOT `virsh console`: virsh only shows what happens after you attach,
# whereas this device also appends everything to a file, so a boot that failed while
# nobody was watching is still readable afterwards.
#
# There is no authentication on that socket. It is a serial line into a machine with a
# passwordless-sudo user, which is why libvirt binds it to loopback only.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/clusters/onprem/nodes.json"

node="${1:-}"
mode="${2:-interactive}"

if [[ -z "$node" ]]; then
  echo "usage: $(basename "$0") <node> [--log|--last]" >&2
  echo "nodes:" >&2
  jq -r '.nodes[] | "  \(.name)  \(.address)"' "$CONFIG" >&2
  exit 1
fi

addr=$(jq -r --arg n "$node" '.nodes[]|select(.name==$n)|.address' "$CONFIG")
if [[ -z "$addr" || "$addr" == "null" ]]; then
  echo "unknown node '$node'. Known nodes:" >&2
  jq -r '.nodes[] | "  \(.name)"' "$CONFIG" >&2
  exit 1
fi

# Must match the derivation in terraform/onprem/main.tf: 12300 + last octet.
port=$(( 12300 + ${addr##*.} ))
log="/var/log/libvirt/qemu/${node}-console.log"

case "$mode" in
  --log)
    echo "==> $log  (Ctrl-C to stop)"
    exec sudo tail -n 200 -f "$log"
    ;;
  --last)
    # Each boot starts with SeaBIOS or GRUB announcing itself. Showing only the last
    # one is usually what you want: the current failure, not every failure since.
    echo "==> last boot from $log"
    sudo awk '/SeaBIOS|GRUB |Booting a command list/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$log" \
      || sudo tail -n 200 "$log"
    ;;
  interactive)
    if ! ss -ltn 2>/dev/null | grep -q "127.0.0.1:$port"; then
      echo "Nothing is listening on 127.0.0.1:$port." >&2
      echo "The domain is probably not running. Try: make onprem-vms-status" >&2
      echo "The recorded log still works: $(basename "$0") $node --log" >&2
      exit 1
    fi
    echo "==> $node serial console on 127.0.0.1:$port"
    echo "    press Enter for a login prompt; detach with Ctrl-]"
    echo "    this console is also being recorded to $log"
    echo
    if command -v socat >/dev/null 2>&1; then
      # raw,echo=0 hands the terminal to the guest rather than the local shell;
      # escape=0x1d makes Ctrl-] detach instead of being sent down the line.
      exec socat -,raw,echo=0,escape=0x1d "TCP:127.0.0.1:$port"
    elif command -v telnet >/dev/null 2>&1; then
      echo "(socat not installed - using telnet, escape is Ctrl-] then 'quit')" >&2
      exec telnet 127.0.0.1 "$port"
    else
      echo "Install socat for a usable console: sudo apt install -y socat" >&2
      echo "Falling back to nc - no line discipline, Ctrl-C to exit." >&2
      exec nc 127.0.0.1 "$port"
    fi
    ;;
  *)
    echo "unknown mode '$mode' (expected --log or --last)" >&2
    exit 1
    ;;
esac
