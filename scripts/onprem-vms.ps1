<#
.SYNOPSIS
    Build or destroy the on-prem Kubernetes VMs from the golden image.

.DESCRIPTION
    Clones the Packer-built template once per node in clusters/onprem/nodes.json, gives each
    clone its own identity, and assigns a static address inside VMware's NAT subnet.

    The subnet is DISCOVERED from the first clone's DHCP lease rather than configured. That is
    deliberate: the previous attempt at this platform spent an evening editing VMware's
    vmnetdhcp.conf with PowerShell string replacement, which is both fragile and unnecessary.
    Static addresses live at .10-.12, far below VMware's NAT pool (which starts at .128), so
    the two allocation schemes cannot collide.

    Remote commands are sent base64-encoded. Quoting a bash script through PowerShell, ssh and
    sudo is a well-known way to lose an hour to escaping bugs; encoding removes the problem.

.EXAMPLE
    .\scripts\onprem-vms.ps1 -Action create
    .\scripts\onprem-vms.ps1 -Action status
    .\scripts\onprem-vms.ps1 -Action destroy
#>
[CmdletBinding()]
param(
    [ValidateSet('create', 'destroy', 'status')]
    [string]$Action = 'create',

    [string]$ConfigPath = "$PSScriptRoot/../clusters/onprem/nodes.json",

    [string]$VmrunPath = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------- helpers

function Write-Step  { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "    $m" -ForegroundColor Yellow }
function Die         { param($m) Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Invoke-Vmrun {
    param([Parameter(ValueFromRemainingArguments)] [string[]]$Arguments)
    $out = & $VmrunPath -T ws @Arguments 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}

function Invoke-OnNode {
    <# Runs a bash script on a node as root, immune to quoting problems. #>
    param([string]$IpAddress, [string]$User, [string]$Script, [int]$TimeoutSec = 120)
    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($Script)
    $encoded = [Convert]::ToBase64String($bytes)
    $remote  = "echo $encoded | base64 -d | sudo bash -s"
    $out = ssh -o StrictHostKeyChecking=no `
               -o UserKnownHostsFile=NUL `
               -o ConnectTimeout=10 `
               -o LogLevel=ERROR `
               "$User@$IpAddress" $remote 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}

function Wait-ForSsh {
    param([string]$IpAddress, [string]$User, [int]$TimeoutSec = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-OnNode -IpAddress $IpAddress -User $User -Script 'exit 0'
        if ($r.ExitCode -eq 0) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

# ---------------------------------------------------------------- preflight

if (-not (Test-Path $VmrunPath)) {
    Die "vmrun.exe not found at '$VmrunPath'. Pass -VmrunPath with the correct location."
}
if (-not (Test-Path $ConfigPath)) { Die "config not found: $ConfigPath" }

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$user = $cfg.ssh.username

# ---------------------------------------------------------------- status

if ($Action -eq 'status') {
    Write-Step 'Running VMs'
    (Invoke-Vmrun list).Output | Write-Host
    Write-Step 'Configured nodes'
    foreach ($n in $cfg.nodes) {
        $vmx = Join-Path $cfg.vm_directory "$($n.name)/$($n.name).vmx"
        $state = if (Test-Path $vmx) { 'exists' } else { 'absent' }
        $ip = ''
        if ($state -eq 'exists') {
            $r = Invoke-Vmrun getGuestIPAddress $vmx
            if ($r.ExitCode -eq 0) { $ip = $r.Output.Trim() }
        }
        '{0,-10} {1,-8} {2,-14} {3}' -f $n.name, $n.role, $state, $ip | Write-Host
    }
    exit 0
}

# ---------------------------------------------------------------- destroy

if ($Action -eq 'destroy') {
    if (-not $Force) {
        $answer = Read-Host "Destroy all $($cfg.nodes.Count) on-prem VMs? Type 'yes'"
        if ($answer -ne 'yes') { Write-Warn2 'aborted'; exit 1 }
    }
    foreach ($n in $cfg.nodes) {
        $vmx = Join-Path $cfg.vm_directory "$($n.name)/$($n.name).vmx"
        if (-not (Test-Path $vmx)) { Write-Warn2 "$($n.name): already absent"; continue }
        Write-Step "Destroying $($n.name)"
        Invoke-Vmrun stop $vmx hard   | Out-Null
        Invoke-Vmrun deleteVM $vmx    | Out-Null
        $dir = Split-Path $vmx -Parent
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
        Write-Ok 'gone'
    }
    Write-Host ''
    Write-Ok 'All VMs destroyed. `-Action create` rebuilds them identically.'
    exit 0
}

# ---------------------------------------------------------------- create

$templateVmx = $cfg.template.vmx
if (-not (Test-Path $templateVmx)) {
    Die "Template not found: $templateVmx`n     Build it first:  cd packer/ubuntu-2404 ; packer init . ; packer build ."
}

# A linked clone needs a snapshot to branch from. Create it once, idempotently.
Write-Step 'Checking template snapshot'
$snaps = Invoke-Vmrun listSnapshots $templateVmx
if ($snaps.Output -notmatch [regex]::Escape($cfg.template.snapshot)) {
    Write-Warn2 "creating snapshot '$($cfg.template.snapshot)'"
    $r = Invoke-Vmrun snapshot $templateVmx $cfg.template.snapshot
    if ($r.ExitCode -ne 0) { Die "snapshot failed: $($r.Output)" }
}
Write-Ok "snapshot '$($cfg.template.snapshot)' present"

if (-not (Test-Path $cfg.vm_directory)) { New-Item -ItemType Directory -Path $cfg.vm_directory -Force | Out-Null }

$subnet = $null
$created = @()

foreach ($n in $cfg.nodes) {
    $dir = Join-Path $cfg.vm_directory $n.name
    $vmx = Join-Path $dir "$($n.name).vmx"

    if (Test-Path $vmx) { Write-Warn2 "$($n.name): already exists, skipping clone"; }
    else {
        Write-Step "Cloning $($n.name)  ($($n.cpus) vCPU, $([int]$n.memory_mb/1024) GB)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $r = Invoke-Vmrun clone $templateVmx $vmx linked "-snapshot=$($cfg.template.snapshot)" "-cloneName=$($n.name)"
        if ($r.ExitCode -ne 0) { Die "clone failed for $($n.name): $($r.Output)" }

        # Resize the clone for its role and force a new identity at the hypervisor level.
        $vmxLines = Get-Content $vmx | Where-Object {
            $_ -notmatch '^(memsize|numvcpus|displayName|uuid\.action)\s*='
        }
        $vmxLines += @(
            "memsize = `"$($n.memory_mb)`""
            "numvcpus = `"$($n.cpus)`""
            "displayName = `"$($n.name)`""
            'uuid.action = "create"'        # new UUID and MAC, so siblings never collide
        )
        # ASCII, no BOM: VMware will not parse a .vmx that begins with a byte-order mark.
        [System.IO.File]::WriteAllLines($vmx, $vmxLines, [System.Text.ASCIIEncoding]::new())
        Write-Ok 'cloned and resized'
    }

    Write-Step "Starting $($n.name)"
    Invoke-Vmrun start $vmx nogui | Out-Null

    Write-Step "Waiting for $($n.name) to report an address (open-vm-tools)"
    $r = Invoke-Vmrun getGuestIPAddress $vmx -wait
    if ($r.ExitCode -ne 0) { Die "no address from $($n.name): $($r.Output)" }
    $dhcpIp = $r.Output.Trim()
    Write-Ok "DHCP address $dhcpIp"

    # Discover the NAT subnet once, from the first node. Nothing is configured on the host.
    if (-not $subnet) {
        $octets = $dhcpIp.Split('.')
        $subnet = "$($octets[0]).$($octets[1]).$($octets[2])"
        Write-Ok "NAT subnet discovered: $subnet.0/$($cfg.network.prefix)"
    }

    $staticIp = "$subnet.$($n.host_offset)"
    $gateway  = "$subnet.$($cfg.network.gateway_offset)"
    $dns      = ($cfg.network.nameservers -join ', ')
    $hostsEntries = ($cfg.nodes | ForEach-Object { "$subnet.$($_.host_offset) $($_.name)" }) -join "`n"

    if (-not (Wait-ForSsh -IpAddress $dhcpIp -User $user)) { Die "ssh never came up on $dhcpIp" }

    Write-Step "Assigning identity to $($n.name)  ->  $staticIp"
    $script = @"
set -euo pipefail

# 1. hostname
hostnamectl set-hostname $($n.name)

# 2. machine-id. The template was sealed with an empty one; regenerate so journald, DHCP
#    and anything else keyed on it see three distinct machines.
if [ ! -s /etc/machine-id ]; then
    systemd-machine-id-setup
fi

# 3. SSH host keys, if the sealed image left none
ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 || ssh-keygen -A

# 4. static addressing, inside the NAT subnet but far below its DHCP pool
IFACE=\$(ip -o -4 route show to default | awk '{print \$5}' | head -1)
cat > /etc/netplan/60-static.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    \$IFACE:
      dhcp4: false
      addresses: [$staticIp/$($cfg.network.prefix)]
      routes:
        - to: default
          via: $gateway
      nameservers:
        addresses: [$dns]
NETPLAN
chmod 600 /etc/netplan/60-static.yaml
rm -f /etc/netplan/50-cloud-init.yaml

# 5. every node can name every other node, before any DNS exists
sed -i '/ k8s-/d' /etc/hosts
cat >> /etc/hosts <<HOSTS
$hostsEntries
HOSTS

# 6. cloud-init must not re-apply its own network config on the next boot
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

echo "identity set: \$(hostnamectl --static) / \$(cat /etc/machine-id)"
"@

    $res = Invoke-OnNode -IpAddress $dhcpIp -User $user -Script $script
    if ($res.ExitCode -ne 0) { Die "identity step failed on $($n.name):`n$($res.Output)" }
    Write-Ok $res.Output.Trim()

    # netplan apply over the link we are using would cut the connection mid-command; a reboot
    # is slower but deterministic, and we are going to verify the node comes back anyway.
    Write-Step "Rebooting $($n.name) onto its static address"
    Invoke-OnNode -IpAddress $dhcpIp -User $user -Script 'systemctl reboot' | Out-Null
    Start-Sleep -Seconds 12

    if (-not (Wait-ForSsh -IpAddress $staticIp -User $user -TimeoutSec 240)) {
        Die "$($n.name) did not come back on $staticIp. Check the VMware console."
    }
    $check = Invoke-OnNode -IpAddress $staticIp -User $user -Script 'hostnamectl --static; ip -br -4 addr show scope global; cat /etc/machine-id'
    Write-Ok ($check.Output -replace "`n", ' | ')
    $created += [pscustomobject]@{ Name = $n.name; Role = $n.role; Address = $staticIp }
}

Write-Host ''
Write-Step 'Verifying every node is distinct'
$ids = foreach ($c in $created) {
    (Invoke-OnNode -IpAddress $c.Address -User $user -Script 'cat /etc/machine-id').Output.Trim()
}
if (($ids | Select-Object -Unique).Count -ne $ids.Count) {
    Die 'Two nodes share a machine-id. Re-run 99-seal.sh in the template and rebuild.'
}
Write-Ok 'machine-ids are unique'

Write-Host ''
$created | Format-Table -AutoSize
Write-Host 'Next: Module 02 - bootstrap the control plane with kubeadm.' -ForegroundColor Cyan
