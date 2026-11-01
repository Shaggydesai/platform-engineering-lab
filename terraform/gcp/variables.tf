locals {
  # One source of truth, the same arrangement as nodes.json on-prem (ADR-0008). Nothing in this
  # directory invents a value that clusters/gcp/cluster.json already holds, so the zone Terraform
  # builds in and the zone the Makefile prints cannot disagree.
  cfg   = jsondecode(file("${path.module}/../../clusters/gcp/cluster.json"))
  nodes = local.cfg.nodes

  name = "platform"

  # Secondary ranges for VPC-native networking. These are POD and SERVICE ranges inside the
  # cluster and have nothing to do with 192.168.100.0/24 on-prem - but they are deliberately the
  # same shape as ADR-0007's on-prem choices so the two substrates read alike:
  #
  #   pods      10.244.0.0/16     (on-prem uses the same, via Cilium)
  #   services  10.96.0.0/12 ->   /20 here, because GKE requires the service range to be
  #                               smaller and a /12 would be rejected
  #
  # They must not overlap the subnet below, or the cluster fails to create with a message about
  # ranges rather than about the overlap.
  subnet_cidr   = "10.10.0.0/20"
  pods_cidr     = "10.244.0.0/16"
  services_cidr = "10.96.0.0/20"
}
