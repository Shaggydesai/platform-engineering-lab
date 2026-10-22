#!/usr/bin/env bash
# Build or destroy the on-prem Kubernetes VMs from the golden image. Runs in WSL.
#
# This is the primary implementation (see ADR-0005). scripts/onprem-vms.ps1 is the Windows-native
# fallback for a machine without WSL; keep them behaviourally identical if you change one.
#
# WSL calls vmrun.exe through Windows interop, so paths crossing the boundary are converted with
# wslpath. Everything else - ssh, jq, the remote scripts - is native Linux, which means the same
# shell, tooling and line endings as the nodes themselves.
#
#   ./scripts/onprem-vms.sh create
#   ./scripts/onprem-vms.sh status
#   ./scripts/onprem-vms.sh destroy [--force]

set -euo pipefail

ACTION="${1:-create}"
FORCE="${2:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-$REPO_ROOT/clusters/onprem/nodes.json}"
# VMware Workstation installs to different paths depending on the build.
if [[ -z "${VMRUN:-}" ]]; then
  for _p in "/mnt/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe" \
            "/mnt/c/Program Files/VMware/VMware Workstation/vmrun.exe"; do
    [[ -x "$_p" ]] && { VMRUN="$_p"; break; }
  done
fi
VMRUN="${VMRUN:-/mnt/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe}"

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n'  "$c_ok"   "$*" "$c_off"; }
warn() { printf '    %s%s%s\n'  "$c_warn" "$*" "$c_off"; }
die()  { printf '%sERROR: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

vmrun() { "$VMRUN" -T ws "$@"; }

# ---------------------------------------------------------------- preflight

preflight() {
  grep -qi microsoft /proc/version \
    || die "not running under WSL. Use scripts/onprem-vms.ps1 from PowerShell instead."
  [[ -x "$VMRUN" ]] \
    || die "vmrun.exe not found. Looked in both Program Files locations.
     Find it with:   ls -d /mnt/c/Program*/VMware*/VMware*
     Then:           VMRUN='/mnt/c/.../vmrun.exe' ./scripts/onprem-vms.sh $ACTION"
  "$VMRUN" -T ws list >/dev/null 2>&1 \
    || die "vmrun.exe is present but would not run. Check Windows interop:
       cat /proc/sys/fs/binfmt_misc/WSLInterop   (should say 'enabled')"
  command -v jq  >/dev/null || die "jq not installed:  sudo apt install -y jq"
  command -v ssh >/dev/null || die "ssh not installed: sudo apt install -y openssh-client"
  [[ -f "$CONFIG" ]] || die "config not found: $CONFIG"
}

# jq helper
cfg() { jq -r "$1" "$CONFIG"; }

# ---------------------------------------------------------------- remote execution

# Runs a script on a node as root. One quoting layer only, because bash talks to bash.
on_node() {
  local ip="$1" user="$2"
  ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -o LogLevel=ERROR \
      "${user}@${ip}" 'sudo bash -s'
}

wait_for_ssh() {
  local ip="$1" user="$2" timeout="${3:-180}" deadline=$(( SECONDS + timeout ))
  while (( SECONDS < deadline )); do
    if echo 'exit 0' | on_node "$ip" "$user" >/dev/null 2>&1; then return 0; fi
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------- actions

do_status() {
  step 'Running VMs'
  vmrun list || true
  step 'Configured nodes'
  local vmdir; vmdir="$(cfg '.vm_directory')"
  while read -r name role offset; do
    local vmx="${vmdir}/${name}/${name}.vmx"
    local vmx_wsl; vmx_wsl="$(wslpath -u "$vmx" 2>/dev/null || true)"
    local state='absent' ip=''
    if [[ -n "$vmx_wsl" && -f "$vmx_wsl" ]]; then
      state='exists'
      ip="$(vmrun getGuestIPAddress "$vmx" 2>/dev/null | tr -d '\r' || true)"
    fi
    printf '%-10s %-14s %-9s %s\n' "$name" "$role" "$state" "$ip"
  done < <(jq -r '.nodes[] | "\(.name) \(.role) \(.host_offset)"' "$CONFIG")
}

do_destroy() {
  local vmdir; vmdir="$(cfg '.vm_directory')"
  if [[ "$FORCE" != "--force" ]]; then
    read -rp "Destroy all on-prem VMs? Type 'yes': " answer
    [[ "$answer" == "yes" ]] || { warn 'aborted'; exit 1; }
  fi
  while read -r name; do
    local vmx="${vmdir}/${name}/${name}.vmx"
    local vmx_wsl; vmx_wsl="$(wslpath -u "$vmx" 2>/dev/null || true)"
    if [[ -z "$vmx_wsl" || ! -f "$vmx_wsl" ]]; then warn "$name: already absent"; continue; fi
    step "Destroying $name"
    vmrun stop "$vmx" hard >/dev/null 2>&1 || true
    vmrun deleteVM "$vmx"   >/dev/null 2>&1 || true
    rm -rf "$(dirname "$vmx_wsl")"
    ok 'gone'
  done < <(jq -r '.nodes[].name' "$CONFIG")
  echo
  ok "All VMs destroyed. './scripts/onprem-vms.sh create' rebuilds them identically."
}

do_create() {
  local tmpl snap vmdir user prefix gw_off
  tmpl="$(cfg '.template.vmx')"
  snap="$(cfg '.template.snapshot')"
  vmdir="$(cfg '.vm_directory')"
  user="$(cfg '.ssh.username')"
  prefix="$(cfg '.network.prefix')"
  gw_off="$(cfg '.network.gateway_offset')"
  local dns; dns="$(jq -r '.network.nameservers | join(", ")' "$CONFIG")"

  local tmpl_wsl; tmpl_wsl="$(wslpath -u "$tmpl" 2>/dev/null || true)"
  [[ -n "$tmpl_wsl" && -f "$tmpl_wsl" ]] || die "Template not found: $tmpl
     Build it first:  cd packer/ubuntu-2404 && packer init . && packer build ."

  step "Checking template snapshot '$snap'"
  if ! vmrun listSnapshots "$tmpl" 2>/dev/null | tr -d '\r' | grep -qx "$snap"; then
    warn "creating snapshot '$snap'"
    vmrun snapshot "$tmpl" "$snap" >/dev/null || die 'snapshot failed'
  fi
  ok 'present'

  local subnet='' created=()

  while read -r name role cpus mem offset; do
    local vmx="${vmdir}/${name}/${name}.vmx"
    local vmx_wsl; vmx_wsl="$(wslpath -u "$vmx" 2>/dev/null || echo '')"

    if [[ -n "$vmx_wsl" && -f "$vmx_wsl" ]]; then
      warn "$name: already exists, skipping clone"
    else
      step "Cloning $name  (${cpus} vCPU, $((mem/1024)) GB)"
      local dir_wsl; dir_wsl="$(wslpath -u "${vmdir}/${name}")"
      mkdir -p "$dir_wsl"
      vmrun clone "$tmpl" "$vmx" linked "-snapshot=${snap}" "-cloneName=${name}" >/dev/null \
        || die "clone failed for $name"
      vmx_wsl="$(wslpath -u "$vmx")"

      # Resize for the role and force a new identity at the hypervisor level. uuid.action=create
      # gives the clone its own UUID and MAC, so siblings cannot collide on the NAT network.
      grep -vE '^(memsize|numvcpus|displayName|uuid\.action)[[:space:]]*=' "$vmx_wsl" > "${vmx_wsl}.new"
      {
        printf 'memsize = "%s"\n' "$mem"
        printf 'numvcpus = "%s"\n' "$cpus"
        printf 'displayName = "%s"\n' "$name"
        printf 'uuid.action = "create"\n'
      } >> "${vmx_wsl}.new"
      # VMware will not parse a .vmx with a BOM or CRLF surprises - write plain, LF, no BOM.
      tr -d '\r' < "${vmx_wsl}.new" > "$vmx_wsl"
      rm -f "${vmx_wsl}.new"
      ok 'cloned and resized'
    fi

    step "Starting $name"
    vmrun start "$vmx" nogui >/dev/null || die "could not start $name"

    step "Waiting for $name to report an address (open-vm-tools)"
    local dhcp_ip
    dhcp_ip="$(vmrun getGuestIPAddress "$vmx" -wait | tr -d '\r')" \
      || die "no address from $name"
    ok "DHCP address $dhcp_ip"

    # Discover the NAT subnet from the first node. VMware's DHCP config is never edited.
    if [[ -z "$subnet" ]]; then
      subnet="${dhcp_ip%.*}"
      ok "NAT subnet discovered: ${subnet}.0/${prefix}"
      if ! ping -c1 -W2 "$dhcp_ip" >/dev/null 2>&1; then
        die "WSL cannot reach $dhcp_ip.
     WSL2 is a separate network namespace and may not route to VMware's vmnet8 by default.
     Options, in order of preference:
       1. Enable mirrored networking: add to C:\\Users\\<you>\\.wslconfig
            [wsl2]
            networkingMode=mirrored
          then 'wsl --shutdown' and reopen.
       2. Run the Windows-native fallback instead: scripts/onprem-vms.ps1"
      fi
    fi

    local static_ip="${subnet}.${offset}"
    local gateway="${subnet}.${gw_off}"
    local hosts_entries
    hosts_entries="$(jq -r --arg s "$subnet" '.nodes[] | "\($s).\(.host_offset) \(.name)"' "$CONFIG")"

    wait_for_ssh "$dhcp_ip" "$user" || die "ssh never came up on $dhcp_ip"

    step "Assigning identity to $name  ->  $static_ip"
    on_node "$dhcp_ip" "$user" <<EOF || die "identity step failed on $name"
set -euo pipefail

hostnamectl set-hostname ${name}

# The template was sealed with an empty machine-id; regenerate so journald, DHCP and anything
# else keyed on it sees three distinct machines.
[ -s /etc/machine-id ] || systemd-machine-id-setup

# SSH host keys, if the sealed image left none
ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 || ssh-keygen -A

IFACE=\$(ip -o -4 route show to default | awk '{print \$5}' | head -1)
cat > /etc/netplan/60-static.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    \${IFACE}:
      dhcp4: false
      addresses: [${static_ip}/${prefix}]
      routes:
        - to: default
          via: ${gateway}
      nameservers:
        addresses: [${dns}]
NETPLAN
chmod 600 /etc/netplan/60-static.yaml
rm -f /etc/netplan/50-cloud-init.yaml

sed -i '/ k8s-/d' /etc/hosts
cat >> /etc/hosts <<HOSTS
${hosts_entries}
HOSTS

# cloud-init must not re-apply its own network config on the next boot
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

echo "identity set: \$(hostnamectl --static) / \$(cat /etc/machine-id)"
EOF

    # Applying netplan over the link we are using would cut the connection mid-command.
    # A reboot is slower and deterministic, and we verify the node comes back anyway.
    step "Rebooting $name onto its static address"
    echo 'systemctl reboot' | on_node "$dhcp_ip" "$user" >/dev/null 2>&1 || true
    sleep 12
    wait_for_ssh "$static_ip" "$user" 240 \
      || die "$name did not come back on $static_ip. Check the VMware console."

    echo 'hostnamectl --static; ip -br -4 addr show scope global | head -2' \
      | on_node "$static_ip" "$user" | tr '\n' ' ' | sed 's/^/    /'
    echo
    created+=("$name $role $static_ip")
  done < <(jq -r '.nodes[] | "\(.name) \(.role) \(.cpus) \(.memory_mb) \(.host_offset)"' "$CONFIG")

  step 'Verifying every node is distinct'
  local ids=()
  for entry in "${created[@]}"; do
    read -r _ _ ip <<< "$entry"
    ids+=("$(echo 'cat /etc/machine-id' | on_node "$ip" "$user" | tr -d '\r\n')")
  done
  local uniq_count; uniq_count="$(printf '%s\n' "${ids[@]}" | sort -u | wc -l)"
  [[ "$uniq_count" -eq "${#ids[@]}" ]] \
    || die 'Two nodes share a machine-id. Re-run 99-seal.sh in the template and rebuild.'
  ok 'machine-ids are unique'

  echo
  printf '%-10s %-14s %s\n' NODE ROLE ADDRESS
  printf '%s\n' "${created[@]}" | awk '{printf "%-10s %-14s %s\n", $1, $2, $3}'
  echo
  step 'Next: Module 02 - bootstrap the control plane with kubeadm.'
}

# ---------------------------------------------------------------- main

preflight
case "$ACTION" in
  create)  do_create  ;;
  destroy) do_destroy ;;
  status)  do_status  ;;
  *) die "unknown action '$ACTION'. Use: create | destroy | status" ;;
esac
