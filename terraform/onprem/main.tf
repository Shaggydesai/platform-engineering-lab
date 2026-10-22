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

  # One serial console port per node, derived from the address rather than declared, so
  # there is no second list to keep in sync: .10 -> 12310, .11 -> 12311, .12 -> 12312.
  # Bound to 127.0.0.1 only - this is a debugging socket with no authentication, and it
  # would be a root shell to anything that could reach it.
  console_port = {
    for n in local.cfg.nodes :
    n.name => 12300 + tonumber(element(split(".", n.address), 3))
  }

  console_log = { for n in local.cfg.nodes : n.name => "/var/log/libvirt/qemu/${n.name}-console.log" }
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

# The seed ISO, uploaded into the storage pool.
#
# libvirt_cloudinit_disk writes its ISO to os.TempDir() and the path is Computed, with no
# attribute to override it - we read the provider source to be sure. On this workstation
# os.TempDir() is /tmp inside WSL, which is cleared whenever WSL shuts down. The domains
# then hold a disk whose backing file does not exist and will not start at all: not a
# degraded boot, a refusal.
#
# So the temp file is treated as what it is - a staging artifact - and the seed itself
# lives in the pool next to the node's root disk. This is the pattern the resource's own
# documentation recommends, and it buys something concrete: a node can be started with
# plain `virsh start`, with no Terraform and no regenerated ISO.
resource "libvirt_volume" "seed" {
  for_each = local.nodes

  name = "${each.key}-seed.iso"
  pool = var.pool

  create = {
    content = {
      url = "file://${libvirt_cloudinit_disk.node[each.key].path}"
    }
  }

  # raw, not qcow2 - this is an ISO 9660 image. Same lesson as the root disk, opposite
  # answer: what matters is telling QEMU the truth about the file it is given.
  target = {
    format = {
      type = "raw"
    }
  }
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
        # The cloud-init NoCloud seed, from the POOL - not from the provider's temp
        # directory, which /tmp clears on every WSL shutdown. cloud-init finds it by its
        # "cidata" filesystem label, so the bus and device name do not matter. raw is
        # correct here: it is an ISO image.
        driver = {
          name = "qemu"
          type = "raw"
        }
        source = {
          file = {
            file = libvirt_volume.seed[each.key].path
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

    # ------------------------------------------------------------------ console
    #
    # Omitting this was the real mistake behind the raw/qcow2 incident. The nodes were
    # unreachable and there was no way to SEE the boot, so the cause had to be inferred
    # from QEMU's command line. A lab whose premise is breaking things must be able to
    # watch a machine fail.
    #
    # Ubuntu's cloud image already boots with console=ttyS0 on the kernel command line,
    # so everything from GRUB onwards lands here. Two capabilities from one device:
    #
    #   log   every boot is appended to a file on the host, recorded whether or not
    #         anyone was watching. This is strictly better than `virsh console`, which
    #         only shows you what happens after you attach.
    #   tcp   an interactive console on 127.0.0.1, for the cases where you must TYPE -
    #         GRUB, single-user mode, or a netplan change that killed the network.
    #         `make onprem-console NODE=k8s-cp01`
    #
    # protocol type is "raw" rather than "telnet" deliberately: raw means socat or nc
    # gives a clean terminal, where telnet negotiation injects IAC bytes into the stream.
    #
    # Only `consoles` is defined, not `serials`. libvirt presents a console whose target
    # type is "serial" to the guest AS the serial port, so defining both would be two
    # declarations of one device - and they must then agree exactly or the domain will
    # not start.
    #
    # Schema verified against the provider's own acceptance tests
    # (internal/provider/domain_resource_test.go, TestAccDomainResource_console*), which
    # is the only description of a 0.9.9 attribute that is guaranteed to be current.
    consoles = [
      {
        source = {
          tcp = {
            mode    = "bind"
            host    = "127.0.0.1"
            service = tostring(local.console_port[each.key])
            tls     = "no"
          }
        }
        protocol = {
          type = "raw"
        }
        target = {
          type = "serial"
          port = 0
        }
        log = {
          # append, so a reboot does not destroy the evidence of why it rebooted.
          file   = local.console_log[each.key]
          append = "on"
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
