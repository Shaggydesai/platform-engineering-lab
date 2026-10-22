// Golden image for every on-prem Kubernetes node.
//
// Built from Ubuntu's official cloud image rather than installed from an ISO. The cloud image is
// the same artefact family AWS and GCE boot, it already contains cloud-init, and it removes the
// autoinstall boot_command - which was the single most timing-fragile step in the previous design.
// Build time drops from roughly twenty minutes to about three.
//
// What goes IN the image: hardening, the container runtime, the Kubernetes packages, kernel
// modules and sysctls - everything identical on all three nodes.
//
// What stays OUT: hostname, machine-id, SSH host keys, IP address, cluster membership. Those are
// identity, and identity is assigned by cloud-init at boot, from Terraform. Baking identity into
// an image is what makes clones collide.
//
//   packer init . && packer build .

packer {
  required_version = ">= 1.9.0"
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "cloud_image_url" {
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  description = "Ubuntu 24.04 LTS generic cloud image, qcow2."
}

variable "cloud_image_checksum" {
  type    = string
  default = "file:https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
}

variable "ssh_username" {
  type    = string
  default = "sagar"
}

variable "ssh_public_key" {
  type        = string
  description = "Injected into the image via the build-time cloud-init seed. Set in variables.auto.pkrvars.hcl."
}

variable "ssh_private_key_file" {
  type    = string
  default = "~/.ssh/id_ed25519"
}

variable "k8s_minor" {
  type        = string
  default     = "v1.34"
  description = "Kubernetes package repository minor version. Pinned deliberately - see 30-kubernetes.sh."
}

variable "output_directory" {
  type    = string
  default = "output"
}

source "qemu" "ubuntu" {
  // The source is a disk image, not installation media.
  iso_url      = var.cloud_image_url
  iso_checksum = var.cloud_image_checksum
  disk_image   = true

  // Keep the base small: every node volume is copy-on-write from this, and libvirt
  // refuses to create a COW volume smaller than its backing file. Nodes size up, never down.
  disk_size        = "20G"
  format           = "qcow2"
  accelerator      = "kvm"
  cpus             = 2
  memory           = 2048
  headless         = true           // no display in WSL; watch progress in Packer's output
  net_device       = "virtio-net"
  disk_interface   = "virtio"

  // A NoCloud seed, attached as a CD labelled "cidata". cloud-init inside the image reads it on
  // first boot and creates the user Packer then connects as. This is the same mechanism the
  // Terraform stack uses later, which is the point: one way of configuring a machine.
  cd_label = "cidata"
  cd_content = {
    "meta-data" = "instance-id: packer-build\nlocal-hostname: ubuntu-template\n"
    "user-data" = templatefile("${path.root}/cloud-init/user-data.tftpl", {
      username   = var.ssh_username
      public_key = var.ssh_public_key
    })
  }

  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_private_key_file   = var.ssh_private_key_file
  ssh_timeout            = "15m"
  ssh_handshake_attempts = 100

  shutdown_command = "sudo shutdown -P now"
  shutdown_timeout = "5m"

  output_directory = var.output_directory
  vm_name          = "ubuntu-2404-k8s.qcow2"
}

build {
  name    = "ubuntu-2404-k8s"
  sources = ["source.qemu.ubuntu"]

  provisioner "shell" {
    execute_command = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "SSH_USERNAME=${var.ssh_username}",
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
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
