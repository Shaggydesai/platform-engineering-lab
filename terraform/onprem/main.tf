# The on-prem substrate: three KVM nodes, built from the Packer golden image, configured by
# cloud-init. This is Layer 0 of ADR-0002, and unlike the script it replaced it has state, a
# plan, and a dependency graph.
#
#   make onprem-vms-validate   check against the provider schema, touches nothing
#   make onprem-vms            terraform apply
#   make onprem-vms-destroy    terraform destroy
#
# Written against the schema of the installed plugin (0.9.9), dumped with
# scripts/provider-schema.sh - not against the published documentation, which describes a
# different version. Two places where they disagree and the schema wins:
#   - os.boot_devices is a list of OBJECTS ({ dev = "hd" }), not a list of strings
#   - libvirt_volume has no top-level `format`; it is target.format.type
#
# Design note: addresses are assigned by cloud-init inside the guest, not by libvirt DHCP
# reservations. That keeps the network definition minimal and means no MAC pinning, no DHCP
# host entries, and no dependence on lease timing. The addresses still live in Git, in
# nodes.json, which was the point of the reservation approach anyway.

locals {
  cfg   = jsondecode(file("${path.module}/${var.nodes_file}"))
  nodes = { for n in local.cfg.nodes : n.name => n }
  net   = local.cfg.network

  ssh_public_key = trimspace(file(pathexpand(local.cfg.ssh.public_key_file)))

  # 192.168.100.0/24 -> 24
  prefix = tonumber(split("/", local.net.cidr)[1])

  # Every node can name every other node before any cluster DNS exists.
  hosts_entries = join("\n", [
    for n in local.cfg.nodes : "${n.address} ${n.name} ${n.name}.${local.net.domain}"
  ])
}

# ---------------------------------------------------------------- network

resource "libvirt_network" "platform" {
  name      = local.net.name
  autostart = true

  forward = {
    mode = "nat"
  }

  ips = [
    {
      family  = "ipv4"
      address = local.net.gateway
      prefix  = local.prefix
    }
  ]
}

# ---------------------------------------------------------------- images
#
# The golden image is uploaded into the pool once. Each node gets a volume backed by it, so
# three nodes cost roughly one image plus whatever each one diverges by.

resource "libvirt_volume" "base" {
  name = "ubuntu-2404-k8s-base.qcow2"
  pool = var.pool

  create = {
    content = {
      url = "file://${abspath("${path.module}/${var.base_image}")}"
    }
  }

  target = {
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_volume" "node" {
  for_each = local.nodes

  name     = "${each.key}.qcow2"
  pool     = var.pool
  capacity = each.value.disk_gb
  # Nodes size UP from the base image. libvirt refuses a backing-store volume smaller than
  # the image behind it, which is why the Packer disk_size is deliberately small.
  capacity_unit = "GiB"

  backing_store = {
    path = libvirt_volume.base.path
    format = {
      type = "qcow2"
    }
  }

  target = {
    format = {
      type = "qcow2"
    }
  }
}

# ---------------------------------------------------------------- cloud-init
#
# Identity lives here, not in the image: hostname, SSH key, static address, hosts file. This
# is the same mechanism EC2 and GCE use, which is why Modules 08 and 09 will look like this.

resource "libvirt_cloudinit_disk" "node" {
  for_each = local.nodes

  name = "${each.key}-cloudinit.iso"

  user_data = templatefile("${path.module}/templates/user-data.tftpl", {
    hostname      = each.key
    domain        = local.net.domain
    username      = local.cfg.ssh.username
    public_key    = local.ssh_public_key
    hosts_entries = local.hosts_entries
    role          = each.value.role
  })

  network_config = templatefile("${path.module}/templates/network-config.tftpl", {
    address     = each.value.address
    prefix      = local.prefix
    gateway     = local.net.gateway
    nameservers = join(", ", local.cfg.network.nameservers)
  })

  meta_data = <<-EOT
    instance-id: ${each.key}-${substr(sha1(each.value.address), 0, 8)}
    local-hostname: ${each.key}
  EOT
}

# ---------------------------------------------------------------- domains

resource "libvirt_domain" "node" {
  for_each = local.nodes

  name   = each.key
  type   = "kvm"
  vcpu   = each.value.cpus
  memory = each.value.memory_mb

  memory_unit = "MiB"
  running     = true
  autostart   = false

  # host-passthrough gives the guest the real CPU flags. Nested inside WSL2 we are already
  # paying for one extra layer of virtualisation; there is no reason to hide instructions too.
  cpu = {
    mode = "host-passthrough"
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    # A list of objects, not a list of strings - the published docs are wrong about this.
    boot_devices = [{ dev = "hd" }]
  }

  devices = {
    disks = [
      {
        # The node's root disk.
        #
        # The driver block is NOT optional. libvirt defaults to type "raw", so without it
        # QEMU hands the guest the qcow2 header as though it were a partition table: the
        # VM boots, finds nothing bootable, and sits there forever with no network and no
        # SSH. The QEMU command line is where this shows up - look for "driver":"raw".
        driver = {
          name = "qemu"
          type = "qcow2"
        }
        source = {
          file = {
            file = libvirt_volume.node[each.key].path
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        # The cloud-init NoCloud seed. cloud-init finds it by its "cidata" filesystem label,
        # so the bus and device name do not matter. raw is correct here - it is an ISO image.
        driver = {
          name = "qemu"
          type = "raw"
        }
        source = {
          file = {
            file = libvirt_cloudinit_disk.node[each.key].path
          }
        }
        target = {
          dev = "vdb"
          bus = "virtio"
        }
        read_only = true
      },
    ]

    interfaces = [
      {
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = libvirt_network.platform.name
          }
        }
      }
    ]
  }

  depends_on = [libvirt_network.platform]
}

# ---------------------------------------------------------------- verification
#
# The module is not finished when Terraform says "apply complete" - it is finished when the
# nodes are reachable and distinct. A clone that kept its parent's machine-id is the failure
# this catches, and it is one that otherwise hides for hours.

resource "terraform_data" "verify" {
  depends_on = [libvirt_domain.node]

  triggers_replace = [for n in local.cfg.nodes : n.address]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      user=${local.cfg.ssh.username}
      ids=""
      fail=0
      for addr in ${join(" ", [for n in local.cfg.nodes : n.address])}; do
        echo "waiting for $addr"
        ok=0
        for i in $(seq 1 24); do
          if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                 -o ConnectTimeout=5 -o LogLevel=ERROR \
                 "$user@$addr" 'exit 0' 2>/dev/null; then ok=1; break; fi
          sleep 5
        done
        if [ "$ok" != 1 ]; then
          echo "ERROR: $addr did not answer ssh within 2 minutes. Run: make onprem-diagnose"
          fail=1; continue
        fi
        read -r host id < <(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o LogLevel=ERROR "$user@$addr" 'echo "$(hostnamectl --static) $(cat /etc/machine-id)"')
        echo "  $addr  $host  $id"
        ids="$ids$id"$'\n'
      done
      [ "$fail" = 0 ] || exit 1
      total=$(printf '%s' "$ids" | grep -c .)
      uniq=$(printf '%s' "$ids" | sort -u | grep -c .)
      if [ "$total" != "$uniq" ]; then
        echo "ERROR: nodes share a machine-id - the image was not sealed. Rebuild with 'make image'."
        exit 1
      fi
      echo "all nodes reachable, machine-ids unique"
    EOT
  }
}
