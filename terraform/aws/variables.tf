# Who may reach SSH and the Kubernetes API.
#
# EMPTY BY DEFAULT, AND THAT MEANS "ASK AWS WHAT MY ADDRESS IS" rather than "allow everything".
# The difference matters: a security group with 0.0.0.0/0 on 22 and 6443 puts a kubeadm API
# server and three SSH daemons on the public internet, and the scanners find them in minutes.
#
# Set it explicitly when the automatic lookup is wrong - behind a VPN that egresses elsewhere, or
# on a connection whose address changes mid-session:
#
#   terraform apply -var 'admin_cidr=203.0.113.4/32'
variable "admin_cidr" {
  description = "CIDR allowed to reach SSH and the API server. Empty means detect this workstation's public address."
  type        = string
  default     = ""

  validation {
    condition     = var.admin_cidr == "" || can(cidrnetmask(var.admin_cidr))
    error_message = "admin_cidr must be empty or a CIDR like 203.0.113.4/32 - a bare address without /32 is rejected by the API with a message about the rule rather than about this value."
  }
}

# checkip.amazonaws.com is AWS's own, it returns the address as plain text with a trailing
# newline, and it is reached from the LAPTOP at plan time rather than from anything in the VPC.
#
# A DETECTED ADDRESS IS A SNAPSHOT, not a fact: a home connection can be renumbered between the
# apply and the next session, at which point SSH stops working and looks like a broken instance.
# When that happens, re-apply - the security group updates in place, no node is replaced.
data "http" "my_ip" {
  count = var.admin_cidr == "" ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

# The newest Canonical Ubuntu 24.04 image, resolved at plan time.
#
# NOT PINNED TO AN AMI ID, deliberately. The ID changes with every Ubuntu point release; a pinned
# one goes stale and fails the apply with a message about an image rather than about a pin. What
# is held constant is the SCRIPTS that run on top of it, which are the same files the Packer
# image bakes for the laptop (ADR-0025) - so the base moving is fine and the definition is not.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = [local.cfg.image.owner]

  filter {
    name   = "name"
    values = [local.cfg.image.name_filter]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  # One source of truth, the same arrangement as the on-prem substrate's nodes.json (ADR-0008)
  # and the GCP substrate's cluster.json. Read rather than duplicated, so this state and the
  # guardrail state cannot disagree about a region or a budget.
  cfg = jsondecode(file("${path.module}/../../clusters/aws/cluster.json"))

  admin_cidr = var.admin_cidr != "" ? var.admin_cidr : "${trimspace(data.http.my_ip[0].response_body)}/32"

  ssh_public_key = trimspace(file(pathexpand(local.cfg.ssh.public_key_file)))

  # THE IMAGE DEFINITION, AND 99-seal.sh IS NOT IN IT - nor is 00-wait-for-cloud-init.sh, and
  # both omissions are load-bearing rather than tidy.
  #
  #   00-wait-for-cloud-init.sh runs `cloud-init status --wait`. Run FROM cloud-init that waits
  #                             for the thing running it. It is a deadlock, not a slow boot.
  #
  #   99-seal.sh                deletes /etc/ssh/ssh_host_*, truncates /etc/machine-id and
  #                             removes every authorized_keys. That is correct for a template
  #                             about to be cloned and catastrophic on a running instance: it
  #                             would lock Ansible out of the node it just built.
  #
  # Both are Packer-lifecycle steps rather than image content, which is exactly the distinction
  # that only becomes visible when the same scripts are delivered a second way.
  image_scripts = [
    "10-base.sh",
    "20-container-runtime.sh",
    "30-kubernetes.sh",
    "40-harden.sh",
  ]

  nodes = merge(
    {
      (local.cfg.nodes.control_plane.name) = {
        role          = "control-plane"
        instance_type = local.cfg.nodes.control_plane.instance_type
      }
    },
    {
      for i in range(local.cfg.nodes.workers.count) :
      format("%s%02d", local.cfg.nodes.workers.name_prefix, i + 1) => {
        role          = "worker"
        instance_type = local.cfg.nodes.workers.instance_type
      }
    },
  )

  # GZIPPED, because user_data is capped at 16 KB and the four scripts are ~7.4 KB before the
  # base64 expansion that would take them past 10. cloud-init decompresses it transparently.
  #
  # The marker file at the end is what anything downstream waits for. WITHOUT IT, Ansible's
  # preflight role races the boot and fails its assertions on a node that is thirty seconds away
  # from passing them - which reads as a broken image rather than as impatience, and is the
  # "transient state read once" shape this project has already paid for twice.
  user_data = base64gzip(join("\n", concat(
    ["#cloud-config"],
    [yamlencode({
      write_files = [
        for s in local.image_scripts : {
          path        = "/opt/image-scripts/${s}"
          permissions = "0755"
          content     = file("${path.module}/../../packer/ubuntu-2404/scripts/${s}")
        }
      ]
      runcmd = concat(
        [for s in local.image_scripts :
          "K8S_MINOR=${local.cfg.kubernetes.minor} bash /opt/image-scripts/${s} >>/var/log/image-build.log 2>&1"
        ],
        [
          "touch /var/lib/cloud/image-ready",
          "echo 'image scripts complete' >>/var/log/image-build.log",
        ],
      )
    })],
  )))
}
