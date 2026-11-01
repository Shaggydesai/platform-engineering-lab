output "cluster_name" {
  value = google_container_cluster.platform.name
}

output "location" {
  description = "A ZONE, not a region. If this ever reads like a region, the free tier no longer applies."
  value       = google_container_cluster.platform.location
}

output "endpoint" {
  description = "The API server address. Not a secret, but not useful without credentials either."
  value       = google_container_cluster.platform.endpoint
}

output "node_pool" {
  value = {
    name         = google_container_node_pool.spot.name
    count        = google_container_node_pool.spot.node_count
    machine_type = local.nodes.machine_type
    spot         = local.nodes.spot
  }
}

output "kubeconfig_command" {
  description = "How to point kubectl at this cluster"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.platform.name} --zone ${local.cfg.zone} --project ${local.cfg.project_id}"
}

output "next" {
  value = <<-EOT
    The cluster exists. Three things, and the third is the one that costs money if skipped.

      1. Point kubectl at it, under a context name that cannot be confused with on-prem:
           make gcp-kubeconfig
           kubectl config get-contexts

      2. Nothing is installed on it yet. The platform arrives through Argo CD from
         gitops/environments/gcp/, which is Module 08's remaining work.

      3. WHEN YOU STOP FOR THE DAY:
           make gcp-down
           make cost-check

         Spot nodes are cheap, not free, and the external IPs on them are billed per hour
         whether or not anything is running on the cluster (ADR-0019 Decision 3). A cluster left
         up overnight is the single most likely way this project spends money.
  EOT
}
