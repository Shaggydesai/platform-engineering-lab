# A zonal GKE cluster with a spot node pool. The managed substrate, ADR-0001's second of three.
#
# NO google_project_service RESOURCES HERE, for the reason ADR-0019 Decision 1c establishes: an
# API that must exist before Terraform can refresh its own state cannot be managed by that
# Terraform. Refreshing a cluster calls the Container API; if that resource lived here, a state
# holding a cluster could not be read without the thing the state creates. `make gcp-up` enables
# compute and container with gcloud first.

# ---------------------------------------------------------------------------- network
#
# Our own VPC rather than the auto-created `default` network, for two reasons that are not
# style. A new project's default network appears only when the Compute API is enabled, and only
# if no org policy suppresses it - so depending on it means depending on something that may
# silently not be there. And the default network has a subnet in every region with permissive
# firewall rules, which is a larger surface than a one-zone lab needs.
resource "google_compute_network" "vpc" {
  name    = "${local.name}-vpc"
  project = local.cfg.project_id

  # No automatic per-region subnets. One subnet, in one region, which is all a zonal cluster uses.
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "nodes" {
  name          = "${local.name}-nodes"
  project       = local.cfg.project_id
  region        = local.cfg.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = local.subnet_cidr

  # VPC-native clusters put pods and services in SECONDARY ranges on the subnet rather than
  # routing them separately. Named here and referenced by the cluster below; a name mismatch
  # produces a cluster-creation error that talks about ranges without saying which end is wrong.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = local.pods_cidr
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = local.services_cidr
  }

  # Lets nodes reach Google APIs without an external IP. It does NOT help with ghcr.io - that is
  # the finding in ADR-0019 Decision 3 - but it costs nothing and means Google-bound traffic from
  # the nodes does not leave via their public addresses.
  private_ip_google_access = true
}

# ---------------------------------------------------------------------------- cluster
resource "google_container_cluster" "platform" {
  name    = local.name
  project = local.cfg.project_id

  # ZONAL. `location` set to a zone rather than a region is the whole difference, and it is the
  # one that decides whether this is free: GKE's free tier covers the management fee for one
  # zonal cluster per billing account per month (ADR-0003, ADR-0019 Decision 2).
  location = local.cfg.zone

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.nodes.id

  # THE LINE THAT MAKES `make gcp-down` WORK.
  #
  # The google provider defaults this to TRUE from 6.0, and with it set a `terraform destroy`
  # fails with "cannot destroy cluster because deletion_protection is set to true" - leaving a
  # cluster running at the end of a session that believed it had torn everything down. For a lab
  # whose entire cost discipline is "destroy it when you are done" (ADR-0003 Decision 4), a
  # safety feature that prevents destruction is the opposite of safe.
  deletion_protection = false

  # The default node pool is created and then immediately removed, because its settings cannot
  # be fully managed in place - spot, machine type and autoscaling belong to a pool resource we
  # own. `initial_node_count = 1` is required even though that node is thrown away.
  remove_default_node_pool = true
  initial_node_count       = 1

  # GKE DATAPLANE V2, and this is not a performance choice - it is what makes NetworkPolicy
  # actually enforced.
  #
  # The first cluster was built without it, and its own destroy plan said so:
  #
  #     network_policy { enabled = false, provider = "PROVIDER_UNSPECIFIED" }
  #     addons_config { network_policy_config { disabled = true } }
  #
  # A GKE cluster with neither Dataplane V2 nor the legacy Calico addon ACCEPTS NetworkPolicy
  # objects and ignores them. ADR-0017's tenant policies would have been created, reported
  # healthy, and enforced nothing - the same failure shape ADR-0016 named for the Ingress object
  # that this cluster would have accepted and never served. `make netpol-check` would have
  # caught it, because probe 2 expects a denied connection; nothing else would.
  #
  # Dataplane V2 is GKE's managed Cilium, which is a pleasing symmetry rather than a coincidence:
  # the on-prem substrate runs Cilium directly (ADR-0007), so both enforce the same plain
  # networking.k8s.io policy with the same engine, one managed and one not.
  #
  # IT CANNOT BE CHANGED AFTER CREATION. Setting it on an existing cluster forces replacement,
  # which is why it is going in now, between a destroy and the next create, rather than later.
  datapath_provider = "ADVANCED_DATAPATH"

  # GATEWAY API, which GKE does not install unless asked. Without this block there are no
  # gateway.networking.k8s.io CRDs and no GKE Gateway controller, so a Gateway object cannot even
  # be applied - and the error names an unknown kind, which reads like a chart problem.
  #
  # The same shape as ADR-0012 Decision 2 on-prem, one layer up: Cilium's gatewayAPI.enabled does
  # nothing at all unless the CRDs already exist, and an operator that starts without them comes
  # up cleanly with Gateway support silently off. Here the CRDs are Google's to install, and this
  # is the switch.
  #
  # CHANNEL_STANDARD is the v1 API (Gateway, HTTPRoute, ReferenceGrant) - the same versions the
  # on-prem cluster gets from the pinned bundle in clusters/onprem/nodes.json. CHANNEL_EXPERIMENTAL
  # would add TCPRoute and TLSRoute, which nothing here uses.
  #
  # ON AN EXISTING CLUSTER this is an update rather than a replacement, as far as I can establish -
  # and it does not much matter either way here, because this cluster is destroyed at the end of
  # every session. If a plan ever says `forces replacement` for this field, that is the moment to
  # read it rather than to type yes.
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Workload Identity: a Kubernetes service account can act as a Google one without a key file.
  # Needed by gitops/environments/gcp/external-secrets.yaml, which authenticates to Secret
  # Manager this way - the cloud equivalent of the Vault Kubernetes auth from Module 07, and the
  # reason that overlay needs no credential at all.
  workload_identity_config {
    workload_pool = "${local.cfg.project_id}.svc.id.goog"
  }

  release_channel {
    # REGULAR rather than RAPID: the on-prem cluster is pinned to one Kubernetes version
    # (v1.34.12, in nodes.json) and a channel that moves weekly would make "the same platform on
    # three substrates" quietly false. REGULAR still auto-upgrades, which is the trade for not
    # managing a control plane.
    channel = "REGULAR"
  }

  # Logging and monitoring are left at GKE's defaults, which is a cost decision and worth stating
  # rather than leaving implicit. Cloud Logging's free tier is 50 GiB per project per month, and
  # a two-node cluster alive for a few hours produces a few hundred megabytes of it. Disabling
  # them would save nothing real and would make the cluster harder to debug in the one module
  # where everything is new.
  #
  # This is the first number to check if the budget alert ever fires: `make cost-check` does not
  # see log ingestion, because nothing lists it as a resource.
}

# ---------------------------------------------------------------------------- nodes
resource "google_container_node_pool" "spot" {
  # `workers`, not `platform-spot`. The pool name is the only part of a GKE node's name this
  # repository controls - VMs are named gke-<cluster>-<pool>-<hash>-<random> by the managed
  # instance group, and the last two have no field. Naming the pool `platform-spot` inside a
  # cluster named `platform` produced `gke-platform-platform-spot-f96b9da4-3wj9`.
  #
  # It does NOT get the names anywhere near on-prem's k8s-w01, and nothing can. See
  # clusters/gcp/cluster.json for why that is a substrate difference rather than a defect.
  name     = local.nodes.pool_name
  project  = local.cfg.project_id
  location = local.cfg.zone
  cluster  = google_container_cluster.platform.name

  node_count = local.nodes.count

  node_config {
    machine_type = local.nodes.machine_type
    disk_size_gb = local.nodes.disk_size_gb
    disk_type    = local.nodes.disk_type

    # SPOT, not `preemptible`. Preemptible is the older generation: a hard 24-hour maximum
    # lifetime and no graceful handling. Spot has no time limit and the same ~60-90% discount,
    # and GKE drains a node it is about to reclaim.
    #
    # The trade is honest and worth meeting in Module 11: a spot node can vanish at any moment.
    # On-prem that failure had to be caused deliberately with `virsh destroy` (ADR-0013); here it
    # arrives on its own, which makes this substrate a better resilience test than the laptop.
    spot = true

    # Needed on the pool as well as the cluster for Workload Identity to work on these nodes.
    # Setting it only on the cluster is the common half-configuration: pods get an identity that
    # silently falls back to the node's service account.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      substrate = "gcp"
      pool      = "spot"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # NO autoscaling block, so the pool stays at exactly node_count.
  #
  # Autoscaling on a free-tier lab is a way to wake up to a bill: a misbehaving workload scales
  # the pool out and nothing stops it except the budget alert, which reports spending rather than
  # preventing it. A fixed two nodes is a hard ceiling, and ADR-0003 prefers ceilings to alerts.
}
