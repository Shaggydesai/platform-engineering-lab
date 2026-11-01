terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source = "hashicorp/google"
      # The same exact pin as the other two GCP states, read from their .terraform.lock.hcl
      # rather than chosen again. Three states on the same provider at three versions is a
      # difference nobody intends and nobody notices until one of them behaves oddly.
      version = "6.50.0"
    }
  }

  # LOCAL STATE, like the cluster's - but the thing it describes is NOT disposable like the
  # cluster's, and that difference deserves naming rather than inheriting.
  #
  # terraform/gcp holds a cluster that is destroyed at the end of every session. This state holds
  # the identity ShopVerse's secrets are read with, and the secret itself. Those survive
  # `make gcp-down` on purpose: regenerating credentials at the start of every session would mean
  # the values differ from one session to the next, which is exactly the failure Module 07 spent
  # a day avoiding on-prem (a fresh `mongo-password` against a database already initialised with
  # the old one - a Running, Ready MongoDB refusing every connection).
  #
  # So why local state anyway, for something that outlives a session? Because the alternative is
  # a GCS bucket, and the abandoned `shopverse-lab` project is the argument against it: it held a
  # `tfstate-684852499708` bucket that outlived everything it described, found only because
  # `make cost-check` was widened after the fact. A remote state for a lab is a thing that
  # survives the lab.
  #
  # The backstop is the same and is better than a backend: if this state is lost, the secret and
  # the service account still exist and can be adopted with `terraform import`, or the project can
  # be deleted outright (ADR-0019 Decision 1b), which removes everything this state could have
  # described. What CANNOT be recovered from a lost state is nothing - the values live in Secret
  # Manager, not here, which is the whole point of Decision 3 below.
}

# `billing_project` and `user_project_override`, for the reason ADR-0019 Decision 6 records at
# length: without them the provider does not send X-Goog-User-Project, and requests are attributed
# to Google's own SDK client project rather than to this one. The error says "set your quota
# project" and the quota project is already set, which is why the diagnosis is written down.
#
# Credentials are Application Default Credentials. There is no service-account key file in this
# repository and there will not be - a downloaded JSON key is a long-lived credential sitting on a
# laptop, which is the exact thing ADR-0018 spent a module removing. The irony of using one to
# reach a secret manager would be total.
provider "google" {
  project               = local.cfg.project_id
  region                = local.cfg.region
  billing_project       = local.cfg.project_id
  user_project_override = true
}
