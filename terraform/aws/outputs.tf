# Outputs exist so the next step can be taken without anybody looking in the console, and so
# that what was built can be CONFIRMED rather than assumed.

output "nodes" {
  description = "Every node, its role, and the addresses Ansible and kubectl need"
  value = {
    for name, inst in aws_instance.node : name => {
      role       = inst.tags["role"]
      public_ip  = inst.public_ip
      private_ip = inst.private_ip
      instance   = inst.id
    }
  }
}

output "control_plane_ip" {
  description = "Public address of the control plane - where kubectl and the kubeadm join point live"
  value       = aws_instance.node[local.cfg.nodes.control_plane.name].public_ip
}

output "admin_cidr" {
  description = "The address admitted to SSH and 6443. Re-apply if your connection is renumbered."
  value       = local.admin_cidr
}

output "ami" {
  description = "The Canonical image resolved at plan time - not pinned, deliberately"
  value       = "${data.aws_ami.ubuntu.id}  ${data.aws_ami.ubuntu.name}"
}

output "hourly_estimate_usd" {
  description = "What this is costing while it exists, excluding any load balancer the cluster creates"
  # Written as arithmetic rather than a number so it stays honest when the node count changes.
  # The spot figure is the measured 2026-11-05 price for m6a.large in ap-south-1; spot moves, so
  # this is an estimate and `make cost-check` plus the console are the authority.
  value = format(
    "~$%.3f/hr  (%d x spot ~$0.0266, %d x %dGB gp3 ~$0.0036/node, %d x public IPv4 $0.005)",
    length(local.nodes) * (0.0266 + 0.0036 + 0.005),
    length(local.nodes), length(local.nodes), local.cfg.nodes.disk_size_gb, length(local.nodes),
  )
}

output "next" {
  value = <<-EOT
    Three instances exist. They are NOT a cluster yet, and they are not ready for Ansible yet.

      1. WAIT FOR THE IMAGE SCRIPTS. cloud-init is running the same four scripts the Packer
         image bakes for the laptop (ADR-0025), which takes about two minutes. Ansible's
         preflight role asserts what those scripts produce, so running it early fails every
         assertion on a node that is thirty seconds from passing them:

           make aws-wait

         or by hand, until it prints the marker:

           ssh -i ~/.ssh/id_ed25519 ${local.cfg.ssh.user}@${aws_instance.node[local.cfg.nodes.control_plane.name].public_ip} \
             'cloud-init status --wait; ls -l /var/lib/cloud/image-ready'

         If it never appears:  sudo tail -50 /var/log/image-build.log

      2. BUILD THE CLUSTER with the same roles the laptop uses - preflight, control_plane,
         gateway_api, cilium, kube_proxy_removal, workers:

           make aws-cluster

      3. THEN Layer 2, which is one role shared by every substrate (ADR-0020):

           make aws-kubeconfig     names the context aws-platform
           make aws-argocd

    AND THE ONE THAT ENDS THE SESSION, whatever else happens (ADR-0003 Decision 5):

           make aws-down
           make cost-check

    This account has NO CREDITS (ADR-0003 Decision 6). ${format("~$%.2f", length(local.nodes) * 0.0352 * 3)} for a three-hour
    session is real money, and three nodes plus a load balancer left overnight is about $1.70 -
    which is what the 50% threshold on the $5 budget is sized to catch.
  EOT
}
