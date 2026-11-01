# Everything the GCP overlay has to name, printed so it can be compared rather than remembered.
#
# `make lint` asserts gitops/environments/gcp/external-secrets.yaml agrees with these, so they are
# not instructions to copy by hand - they are here so a human can see what the checked values are
# without reading Terraform.

output "service_account_email" {
  description = "The Google service account External Secrets acts as. Goes in the overlay's iam.gke.io/gcp-service-account annotation."
  value       = google_service_account.external_secrets.email
}

output "secret_id" {
  description = "The Secret Manager secret ID. This is the tenant overlay's externalSecret.remoteKey - 'shopverse-prod', not 'shopverse/prod', because Secret Manager IDs forbid the slash Vault's hierarchy uses."
  value       = google_secret_manager_secret.shopverse.secret_id
}

output "workload_identity_member" {
  description = "The principal allowed to impersonate that account. Square brackets and all; a mismatch here fails in the pod as a 403 on the metadata server, not at apply time."
  value       = google_service_account_iam_member.eso_impersonates.member
}

output "next" {
  description = "What to do once this state is applied"
  value       = <<-EOT
    The identity and the empty secret exist. The secret has NO VERSION yet, which means
    ShopVerse would get an ExternalSecret that cannot resolve.

      1. Put the values in. They are generated fresh, streamed in on stdin, and never
         written to disk or passed in a shell argument:

           make gcp-secrets-seed

      2. Check it from outside Terraform - that a version exists, that it parses as JSON,
         and that it holds exactly the six keys the tenant's chart asks for:

           make gcp-secrets-verify

    WHAT THIS STATE DELIBERATELY SURVIVES: `make gcp-down`. Regenerating credentials at the
    start of every session would hand a fresh mongo-password to a database initialised with
    the previous one - the failure Module 07 spent a day avoiding on-prem, presenting as a
    Running, Ready MongoDB that refuses every connection.

    IT IS ALSO NOT FREE FOREVER. Secret Manager gives six active secret versions per month;
    this uses one. Each reseed adds a version, so destroy the old ones (make
    gcp-secrets-verify prints the count) or the seventh costs a standing charge, which
    ADR-0003 forbids however small.

    To remove it all, including every version of the secret:

      make gcp-secrets-destroy
  EOT
}
