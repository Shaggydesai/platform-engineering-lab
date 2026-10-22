terraform {
  required_version = ">= 1.5.0"

  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
      # EXACT, not "~> 0.9". A pessimistic constraint with two components means
      # ">= 0.9, < 1.0", which is how "~> 0.8" silently installed 0.9.9 - a release that
      # breaks compatibility with 0.8 (plugin framework rewrite, no migration tool).
      # Infrastructure providers get exact pins; upgrades are a deliberate commit.
      version = "0.9.9"
    }
  }
}

# qemu:///system, not qemu:///session: system-wide libvirt owns the NAT network and the default
# storage pool. Your user must be in the 'libvirt' group - scripts/install-tools.sh does that.
provider "libvirt" {
  uri = var.libvirt_uri
}
