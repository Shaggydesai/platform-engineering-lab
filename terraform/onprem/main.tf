# The on-prem substrate: three KVM nodes, built from the Packer golden image, configured by
# cloud-init. This is Layer 0 of ADR-0002, and unlike the script it replaced it has state, a
# plan, and a dependency graph.
#
#   make onprem-vms            terraform apply
#   make onprem-vms-destroy    terraform destroy
#
# Nothing here is specific to the lab beyond the values in nodes.json. The same shape appears in
# terraform/gcp and terraform/aws later, which is the point of ADR-0001.

locals {
  cfg   = jsondecode(file("${path.module}/${var.nodes_file}"))
  nodes = { for n in local.cfg.nodes : n.name => n }
  net   = local.cfg.network

  ssh_public_key = trimspace(file(pathexpand(local.cfg.ssh.public_key_file)))

  # Every node can name every other node before any cluster DNS exists.
  hosts_entries = join("\n", [
    for n in local.cfg.nodes : "${n.address} ${n.name} ${n.name}.${local.net.domain}"
  ])
}

# ---------------------------------------------------------------- network
#
# NAT with DHCP enabled, but every address is a static reservation keyed on the MAC declared in
# nodes.json. The nodes therefore boot with plain DHCP - exactly as a cloud instance does - while
# the addresses are fixed in version control. No DHCP server configuration is ever edited by hand,
# which was a genuine time sink in the previous attempt at this platform.

resource "libvirt_network" "platform" {
  name      = local.net.name
  mode      = "nat"
  domain    = local.net.domain
  addresses = [local.net.cidr]
  autostart = true

  dhcp {
    enabled = true
  }

  dns {
    enabled    = true
    local_only = false
  }
}

# ---------------------------------------------------------------- images
#
# The golden image is uploaded into the pool once. Each node then gets a copy-on-write volume
# backed by it, so three 35 GB nodes cost roughly the size of one image plus their divergence.

resource "libvirt_volume" "base" {
  name   = "ubuntu-2404-k8s-base.qcow2"
  pool   = var.pool
  source = abspath("${path.module}/${var.base_image}")
  format = "qcow2"
}

resource "libvirt_volume" "node" {
  for_each = local.nodes

  name           = "${each.key}.qcow2"
  pool           = var.pool
  base_volume_id = libvirt_volume.base.id
  size           = each.value.disk_gb * 1024 * 1024 * 1024
  format         = "qcow2"
}

# ---------------------------------------------------------------- cloud-init
#
# Identity lives here, not in the image: hostname, the SSH key, and the hosts file. This is the
# same mechanism EC2 and GCE use, which is why Modules 08 and 09 will look like this one.

resource "libvirt_cloudinit_disk" "node" {
  for_each = local.nodes

  name = "${each.key}-cloudinit.iso"
  pool = var.pool

  user_data = templatefile("${path.module}/templates/user-data.tftpl", {
    hostname      = each.key
    domain        = local.net.domain
    username      = local.cfg.ssh.username
    public_key    = local.ssh_public_key
    hosts_entries = local.hosts_entries
    role          = each.value.role
  })

  meta_data = <<-EOT
    instance-id: ${each.key}-${substr(sha1(each.value.mac), 0, 8)}
    local-hostname: ${each.key}
  EOT
}

# ---------------------------------------------------------------- domains

resource "libvirt_domain" "node" {
  for_each = local.nodes

  name      = each.key
  memory    = each.value.memory_mb
  vcpu      = each.value.cpus
  autostart = false
  qemu_agent = true

  cloudinit = libvirt_cloudinit_disk.node[each.key].id

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.node[each.key].id
  }

  network_interface {
    network_id     = libvirt_network.platform.id
    mac            = each.value.mac
    addresses      = [each.value.address]   # static DHCP reservation
    hostname       = each.key
    wait_for_lease = true
  }

  # Serial console, so `virsh console <node>` works. There is no GUI in WSL, and a reachable
  # console is what you need at three in the morning when networking is the thing that broke.
  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }
}

# ---------------------------------------------------------------- verification
#
# The module is not done when Terraform says "apply complete" - it is done when the nodes are
# reachable and distinct. This checks that every node answers SSH and that no two share a
# machine-id, which is the failure a cloned image produces and which hides for hours.

resource "terraform_data" "verify" {
  depends_on = [libvirt_domain.node]

  triggers_replace = [for n in local.nodes : n.address]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ids=""
      for addr in ${join(" ", [for n in local.cfg.nodes : n.address])}; do
        echo "waiting for $addr"
        for i in $(seq 1 60); do
          if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                 -o ConnectTimeout=5 -o LogLevel=ERROR \
                 ${local.cfg.ssh.username}@$addr 'exit 0' 2>/dev/null; then break; fi
          sleep 5
          [ "$i" = 60 ] && { echo "ERROR: $addr never answered ssh"; exit 1; }
        done
        id=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                 -o LogLevel=ERROR ${local.cfg.ssh.username}@$addr 'cat /etc/machine-id')
        host=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                 -o LogLevel=ERROR ${local.cfg.ssh.username}@$addr 'hostnamectl --static')
        echo "  $addr  $host  $id"
        ids="$ids$id\n"
      done
      uniq_count=$(printf "$ids" | sort -u | grep -c .)
      total=$(printf "$ids" | grep -c .)
      if [ "$uniq_count" != "$total" ]; then
        echo "ERROR: nodes share a machine-id - the image was not sealed correctly"
        exit 1
      fi
      echo "all nodes reachable, machine-ids unique"
    EOT
  }
}
