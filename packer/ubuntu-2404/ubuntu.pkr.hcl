// Golden image for every on-prem Kubernetes node.
//
// What goes IN the image: the operating system, hardening, the container runtime, the
// Kubernetes packages, kernel modules and sysctls - everything identical on all three nodes.
//
// What deliberately stays OUT: hostname, machine-id, SSH host keys, IP address, and any
// cluster membership. Those are identity, and identity is assigned at clone time by
// scripts/onprem-vms.ps1. Baking identity into an image is what makes two nodes collide.
//
// Build:  packer init . && packer build .

packer {
  required_version = ">= 1.9.0"
  required_plugins {
    vmware = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

variable "iso_url" {
  type        = string
  default     = "https://releases.ubuntu.com/24.04/ubuntu-24.04.5-live-server-amd64.iso"
  description = "If this 404s, Ubuntu published a new point release - check https://releases.ubuntu.com/24.04/"
}

variable "iso_checksum" {
  type    = string
  // Reads the official SHA256SUMS instead of hardcoding a hash that goes stale.
  default = "file:https://releases.ubuntu.com/24.04/SHA256SUMS"
}

variable "ssh_username" {
  type    = string
  default = "sagar"
}

variable "ssh_password" {
  type        = string
  default     = "platform"
  description = "Build-time only. Password auth is disabled by 30-harden.sh before the image is sealed."
  sensitive   = true
}

variable "ssh_public_key" {
  type        = string
  default     = ""
  description = "Your workstation's public key, injected into the image. Set it in variables.auto.pkrvars.hcl."
}

variable "output_directory" {
  type        = string
  default     = "C:/VMs/templates/ubuntu-2404-k8s"
  description = "MUST live on the SSD (C:). See ADR-0004 - etcd on the mechanical disk is a known failure mode."
}

variable "k8s_minor" {
  type        = string
  default     = "v1.34"
  description = "Kubernetes package repository minor version."
}

source "vmware-iso" "ubuntu" {
  // --- installation media
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  // --- virtual hardware: the template is modest; clones are resized per role
  guest_os_type    = "ubuntu-64"
  cpus             = 2
  memory           = 2048
  disk_size        = 35840          // 35 GB, thin provisioned
  disk_type_id     = "0"            // single growable virtual disk
  network          = "nat"
  network_adapter_type = "vmxnet3"
  sound            = false
  usb              = false
  version          = "21"

  // --- autoinstall: Packer serves http/ over HTTP, the installer fetches it
  http_directory = "http"
  boot_wait      = "5s"
  boot_command = [
    "<wait3s>c<wait3s>",
    "linux /casper/vmlinuz --- autoinstall ds=\"nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/\"<enter><wait5s>",
    "initrd /casper/initrd<enter><wait5s>",
    "boot<enter>"
  ]

  // --- how Packer talks to the machine once the installer finishes
  communicator         = "ssh"
  ssh_username         = var.ssh_username
  ssh_password         = var.ssh_password
  ssh_timeout          = "45m"      // autoinstall + first boot is slow; this is not a hang
  ssh_handshake_attempts = 100
  shutdown_command     = "echo '${var.ssh_password}' | sudo -S shutdown -P now"
  shutdown_timeout     = "10m"

  // --- output
  output_directory = var.output_directory
  vm_name          = "ubuntu-2404-k8s"
  headless         = false          // watch the first build; set true once it is boring

  vmx_data = {
    "tools.syncTime"              = "TRUE"
    "time.synchronize.continue"   = "TRUE"
    "time.synchronize.restore"    = "TRUE"
    "time.synchronize.resume.disk" = "TRUE"
    "time.synchronize.shrink"     = "TRUE"
    "virtualHW.version"           = "21"
  }
}

build {
  name    = "ubuntu-2404-k8s"
  sources = ["source.vmware-iso.ubuntu"]

  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    environment_vars = [
      "SSH_USERNAME=${var.ssh_username}",
      "SSH_PUBLIC_KEY=${var.ssh_public_key}",
      "K8S_MINOR=${var.k8s_minor}",
    ]
    scripts = [
      "scripts/00-wait-for-cloud-init.sh",
      "scripts/10-base.sh",
      "scripts/20-container-runtime.sh",
      "scripts/30-kubernetes.sh",
      "scripts/40-harden.sh",
      "scripts/99-seal.sh",
    ]
    expect_disconnect = false
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
