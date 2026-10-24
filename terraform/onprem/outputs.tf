output "nodes" {
  description = "What was built, and how to reach it."
  value = {
    for name, n in local.nodes : name => {
      role     = n.role
      address  = n.address
      cpus     = n.cpus
      memory   = "${n.memory_mb / 1024} GB"
      disk     = "${n.disk_gb} GB"
      ssh      = "ssh ${local.cfg.ssh.username}@${n.address}"
      console  = "make onprem-console NODE=${name}"
      boot_log = local.console_log[name]
    }
  }
}

output "control_plane" {
  description = "Address of the control plane node, used by Module 02 and by Ansible."
  value       = [for n in local.cfg.nodes : n.address if n.role == "control-plane"][0]
}

output "verify_commands" {
  description = "Run these by hand if something looks wrong."
  value = {
    list_domains = "virsh -c qemu:///system list --all"
    console      = "make onprem-console NODE=<node>      # interactive, escape with Ctrl-]"
    boot_log     = "sudo tail -f /var/log/libvirt/qemu/<node>-console.log"
    net_dhcp     = "virsh -c qemu:///system net-dumpxml ${local.net.name}"
    ssh          = "ssh ${local.cfg.ssh.username}@${[for n in local.cfg.nodes : n.address][0]}"
  }
}

output "network" {
  value = {
    name    = local.net.name
    cidr    = local.net.cidr
    gateway = local.net.gateway
    domain  = local.net.domain
  }
}
