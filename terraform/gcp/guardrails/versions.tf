terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source = "hashicorp/google"
      # (terraform fmt will align these two; it could not be run in the authoring environment)
      # NOT an exact pin, and that is a deliberate, temporary exception to the rule the on-prem
      # provider block states so firmly.
      #
      # terraform/onprem/versions.tf pins `libvirt = 0.9.9` exactly, and the comment there
      # explains why: a loose constraint silently installed a provider that broke compatibility.
      # That rule still stands. The reason it is not followed here yet is that the authoring
      # environment could not reach registry.terraform.io and has no terraform binary, so the
      # current 6.x patch version could not be read - and this project has an entire script
      # (`make gitops-check-pins`) because three version pins written from memory were wrong,
      # one of them for a release that did not exist.
      #
      # So: a bounded range for the FIRST `terraform init`, which resolves the real version and
      # writes it with its hashes into .terraform.lock.hcl. The lock file is the actual pin -
      # Terraform enforces it on every subsequent init, and it is committed. Then the exact
      # version moves into this block in its own commit, with the value taken from the lock file
      # rather than from anyone's recollection.
      #
      # `make gcp-guardrails` prints that follow-up step after the first apply, so it is a
      # remembered thing rather than a hoped-for one.
      version = ">= 6.0.0, < 7.0.0"
    }
  }
}

# No `zone` or `region` here, and no `credentials`.
#
# A billing budget is attached to the BILLING ACCOUNT, not to a project or a region, so this
# provider needs none of them. `project` is set only to give the API calls a quota project -
# without it, requests are billed against no project and fail with a message about quota that
# does not mention the project.
#
# Credentials come from Application Default Credentials: `gcloud auth application-default login`
# on the workstation. There is no service-account key file anywhere in this repository and there
# will not be - a downloaded JSON key is a long-lived credential on a laptop, which is the exact
# thing ADR-0018 spent a module removing.
provider "google" {
  project = local.cfg.project_id
}
