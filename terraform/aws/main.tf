# Three spot EC2 instances, a VPC with one public subnet, and nothing else.
#
# THE SHAPE IS THE LAPTOP'S, NOT GKE'S (docs/roadmap.md, Module 09): one control plane and two
# workers, built by Terraform and then turned into a cluster by the SAME ansible/roles that build
# the libvirt VMs. That is the question this module exists to answer - whether Layers 0 and 1
# port - and a managed control plane cannot answer it, because on EKS those roles have nothing
# to do.
#
# WHAT IS DELIBERATELY ABSENT, each one a line item ADR-0003 Decision 2 forbids:
#
#   no NAT gateway          ~$0.045/hour plus per-GB, the most expensive idle object in either
#                           cloud. Public subnet and public IPs instead (clusters/aws/cluster.json).
#   no Elastic IPs          an EIP bills while UNATTACHED, which is precisely the state a failed
#                           teardown leaves it in. The addresses here die with the instances.
#   no AMI                  an AMI is a standing EBS snapshot. The image scripts run at boot.
#   no load balancer        the ingress layer creates one from inside the cluster when it runs,
#                           and `make aws-down` must remove it BEFORE this state is destroyed -
#                           ADR-0021 learned that ordering twice on GCP.

resource "aws_vpc" "platform" {
  cidr_block = local.cfg.networking.vpc_cidr

  # Both on, and the second one is why. Cilium does not need them - pods get overlay addresses -
  # but the NODES resolve archive.ubuntu.com and pkgs.k8s.io at first boot for the image scripts,
  # and a VPC without DNS support fails that in a way that looks like a broken mirror.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.cfg.cluster_name}-vpc" }
}

resource "aws_internet_gateway" "platform" {
  vpc_id = aws_vpc.platform.id
  tags   = { Name = "${local.cfg.cluster_name}-igw" }
}

# ONE SUBNET, IN ONE AZ. EKS would have required two; kubeadm does not, and cross-AZ traffic is
# billed per GB in both directions, so a three-node cluster split across zones would pay for
# every etcd heartbeat (clusters/aws/cluster.json, _az_comment).
resource "aws_subnet" "nodes" {
  vpc_id                  = aws_vpc.platform.id
  cidr_block              = local.cfg.networking.subnet_cidr
  availability_zone       = local.cfg.availability_zone
  map_public_ip_on_launch = local.cfg.nodes.public_ip

  tags = { Name = "${local.cfg.cluster_name}-nodes" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.platform.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.platform.id
  }

  tags = { Name = "${local.cfg.cluster_name}-public" }
}

resource "aws_route_table_association" "nodes" {
  subnet_id      = aws_subnet.nodes.id
  route_table_id = aws_route_table.public.id
}

# THE SECURITY GROUP IS THE WHOLE PERIMETER, because the nodes are on a public subnet with public
# addresses. On-prem the equivalent boundary is a NAT network inside one laptop that nothing can
# reach; here it is these rules and nothing else, which is a real difference between the
# substrates rather than a cosmetic one.
resource "aws_security_group" "nodes" {
  name        = "${local.cfg.cluster_name}-nodes"
  description = "platform-engineering-lab cluster nodes"
  vpc_id      = aws_vpc.platform.id

  tags = { Name = "${local.cfg.cluster_name}-nodes" }
}

# EVERYTHING BETWEEN NODES, AND THAT IS ONE RULE RATHER THAN TWELVE.
#
# Enumerating the ports would mean listing 6443, etcd's 2379-2380, the kubelet's 10250, Cilium's
# VXLAN on 8472/udp, its health checks, NodePort's 30000-32767, and whatever the next module
# adds - and getting one wrong produces a cluster that half works, which is the most expensive
# kind of broken. The boundary that matters is "inside this cluster or not", and self = true is
# exactly that statement.
resource "aws_vpc_security_group_ingress_rule" "node_to_node" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
  description                  = "all traffic between cluster nodes"
}

# SSH and the API server, FROM ONE ADDRESS - see variables.tf for how it is found and when it
# goes stale.
resource "aws_vpc_security_group_ingress_rule" "admin_ssh" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = local.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH from the workstation Ansible runs on"
}

resource "aws_vpc_security_group_ingress_rule" "admin_api" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = local.admin_cidr
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
  description       = "kube-apiserver from the workstation kubectl runs on"
}

# EGRESS IS UNRESTRICTED, and that is a known debt rather than an oversight. The nodes need
# archive.ubuntu.com and pkgs.k8s.io at boot and ghcr.io for the tenant's seven images, and the
# parking lot already carries the equivalent entry for the on-prem tenant ("Tenant egress is
# unrestricted", 2026-10-30). Restricting it here would make this substrate stricter than the
# one it is being compared against, which would quietly spoil the comparison.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "outbound: package mirrors, pkgs.k8s.io, ghcr.io"
}

resource "aws_key_pair" "admin" {
  key_name   = "${local.cfg.cluster_name}-admin"
  public_key = local.ssh_public_key

  tags = { Name = "${local.cfg.cluster_name}-admin" }
}

resource "aws_instance" "node" {
  for_each = local.nodes

  ami           = data.aws_ami.ubuntu.id
  instance_type = each.value.instance_type
  subnet_id     = aws_subnet.nodes.id
  key_name      = aws_key_pair.admin.key_name

  vpc_security_group_ids = [aws_security_group.nodes.id]

  # SPOT, for the ~72% discount measured on 2026-11-05 - and with a trade worth stating rather
  # than discovering. An instance can be reclaimed at two minutes' notice, and losing the
  # CONTROL PLANE is a different event from losing a worker: this cluster has no answer for it,
  # the session simply ends. Module 11 makes that the subject instead of the accident.
  #
  # No max_price, so the cap is the on-demand price. Setting one lower is how a cluster fails to
  # launch at 3pm for reasons that look like capacity.
  instance_market_options {
    market_type = "spot"
    spot_options {
      # TERMINATE, not stop or hibernate. A stopped spot instance keeps its EBS volume, which
      # keeps billing, which is the orphan ADR-0021 already found once on GCP.
      instance_interruption_behavior = "terminate"
    }
  }

  root_block_device {
    volume_size = local.cfg.nodes.disk_size_gb
    volume_type = local.cfg.nodes.disk_type
    encrypted   = true
    # Dies with the instance. The default is already true for a root volume; it is written out
    # because the one thing this project will not do again is leave a disk behind.
    delete_on_termination = true
  }

  user_data_base64 = local.user_data

  # REPLACE THE NODE WHEN THE IMAGE DEFINITION CHANGES, which is the point of putting the scripts
  # in user_data rather than running them by hand afterwards. Editing 30-kubernetes.sh and
  # re-applying rebuilds the nodes; it does not leave three hosts disagreeing about what the
  # image is.
  user_data_replace_on_change = true

  tags = {
    Name = each.key
    # The same two labels GKE's node pool sets, so `kubectl get nodes -L substrate,pool` reads
    # the same way on both - and the Ansible inventory can group on role without parsing names.
    pool = each.value.role
    role = each.value.role
  }
}
