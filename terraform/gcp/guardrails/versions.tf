terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source = "hashicorp/google"
      # EXACT, matching the rule terraform/onprem/versions.tf states and for the same reason.
      #
      # This was a bounded range (">= 6.0.0, < 7.0.0") for exactly one `terraform init`, because
      # the authoring environment could not reach registry.terraform.io to read the current patch
      # version and this project has `make gitops-check-pins` precisely because three pins written
      # from memory were wrong. That init resolved 6.50.0 and wrote it with its hashes into
      # .terraform.lock.hcl, so the version below is READ from a real resolution rather than
      # recalled - which was the whole point of deferring it.
      #
      # .terraform.lock.hcl is committed and is the stronger pin: it carries the hashes, so a
      # re-published 6.50.0 would fail verification rather than install quietly.
      version = "6.50.0"
    }
  }
}

# `user_project_override` and `billing_project` are not boilerplate. Without them the first apply
# failed, and the error named its own cause if you read the metadata rather than the message:
#
#     Error 403: ... The billingbudgets.googleapis.com API requires a quota project, which is
#     not set by default.
#     "consumer": "projects/764086051850"
#     "reason": "SERVICE_DISABLED"
#
# 764086051850 is GOOGLE'S OWN Cloud SDK client project, not shopverse-lab. So the request was
# being attributed to a project this account does not own and on which the Budget API is, quite
# reasonably, disabled - and the prose ("set your quota project") sends you to re-run
# `gcloud auth application-default set-quota-project`, which was already done: the ADC login
# output said "Quota project shopverse-lab was added to ADC".
#
# ADC having a quota project and the PROVIDER SENDING it are different things. The google provider
# only attaches the X-Goog-User-Project header when user_project_override is true, and
# billing_project is which project it names. This class of API - billing budgets, and several
# others that are account-scoped rather than project-scoped - has nowhere else to get a project
# from, so it is the one case where the header is mandatory rather than an optimisation.
#
# The diagnosis is kept here because the error message actively points away from it.
provider "google" {
  project               = local.cfg.project_id
  billing_project       = local.cfg.project_id
  user_project_override = true
}

# No `zone`, no `region`, and no `credentials`.
#
# A billing budget attaches to the BILLING ACCOUNT, not to a project or a region, so this provider
# needs neither. Credentials come from Application Default Credentials
# (`gcloud auth application-default login`); there is no service-account key file in this
# repository and there will not be - a downloaded JSON key is a long-lived credential sitting on a
# laptop, which is the exact thing ADR-0018 spent a module removing.
