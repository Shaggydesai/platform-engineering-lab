terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source = "hashicorp/google"
      # Same exact pin as the guardrail state, read from its .terraform.lock.hcl rather than
      # chosen independently. Two states on the same provider at different versions is a
      # difference nobody intends and nobody notices until one of them behaves oddly.
      version = "6.50.0"
    }
  }

  # LOCAL STATE, deliberately, and the earlier attempt is the argument for it.
  #
  # The obvious move is a GCS backend, and the abandoned `shopverse-lab` project had exactly
  # that: a `tfstate-684852499708` bucket that outlived everything it described. A remote state
  # for a disposable lab is a thing that survives the lab.
  #
  # Local state here is disposable in the same way the cluster is, and the backstop is better
  # than a backend: if the state is lost, `gcloud projects delete` removes everything it could
  # have described (ADR-0019 Decision 1b). That is a stronger recovery than a state file,
  # because it cannot be out of date.
  #
  # This stops being right the moment anything in GCP needs to outlive a session, and that is
  # the signal to revisit rather than a rule to keep.
}

# `billing_project` and `user_project_override` for the same reason as the guardrail state
# (ADR-0019 Decision 6): without them the provider does not send X-Goog-User-Project, and
# requests are attributed to Google's own SDK project rather than to this one.
#
# Credentials are Application Default Credentials. No service-account key file exists in this
# repository and none will.
provider "google" {
  project               = local.cfg.project_id
  region                = local.cfg.region
  zone                  = local.cfg.zone
  billing_project       = local.cfg.project_id
  user_project_override = true
}
