terraform {
  required_version = ">= 1.5.0"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8"
    }
  }
}

# qemu:///system, not qemu:///session: system-wide libvirt owns the NAT network and the default
# storage pool. Your user must be in the 'libvirt' group - scripts/install-tools.sh does that.
provider "libvirt" {
  uri = var.libvirt_uri
}
