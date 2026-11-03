terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # A BOUNDED RANGE FOR EXACTLY ONE `terraform init`, then pinned exactly - the same sequence
      # terraform/gcp/guardrails/versions.tf went through, written down here so the next reader
      # knows this line is unfinished rather than sloppy.
      #
      # The authoring environment cannot reach registry.terraform.io, so the current 5.x patch
      # version cannot be read, and this repository has `make gitops-check-pins` precisely because
      # three pins written from memory were wrong. So: a range now, and the FIRST `terraform init`
      # on the laptop resolves a real version and writes it with its hashes into
      # .terraform.lock.hcl.
      #
      # THEN DO BOTH OF THESE, and `make lint` enforces the second:
      #
      #   1. Replace the range below with the exact version the lock file names.
      #   2. Commit the lock file:
      #        git add -f terraform/aws/guardrails/.terraform.lock.hcl
      #
      # The lock file is the stronger pin because it carries hashes: a re-published version would
      # fail verification rather than install quietly. Two of four Terraform states in this
      # repository had no committed lock file on 2026-11-01 - a rule stated in one comment and
      # enforced nowhere - which is now a lint check rather than a hope.
      version = ">= 5.0.0, < 6.0.0"
    }
  }
}

# REGION IS SET AND IMMATERIAL, which is worth one sentence so nobody "fixes" it.
#
# AWS Budgets is an account-scoped service with a global endpoint - the budget is not in a region
# any more than a GCP billing budget is in a zone. The provider still needs a region to construct a
# session, so it reads the configured one rather than leaving it to whatever is in the operator's
# environment: a provider that silently inherits AWS_REGION is a provider whose behaviour depends
# on the shell it was run from.
provider "aws" {
  region = local.cfg.region

  # NO `access_key`, NO `secret_key`, AND NO `profile`.
  #
  # Credentials come from the operator's own ~/.aws (via `aws configure`, SSO, or an instance
  # role). Hardcoding a profile name here would make this state work on one laptop; hardcoding
  # keys would put a long-lived credential in a public repository, which is the exact thing
  # ADR-0018 spent a module removing from the GCP path when it refused to download a
  # service-account key.
  default_tags {
    tags = {
      # So anything this repository creates in AWS can be found by tag rather than by memory -
      # which is how `make cost-check` grew from "the project you are standing in" to "every
      # project on the account" after an abandoned state turned up with resources in it.
      project    = "platform-engineering-lab"
      managed_by = "terraform"
    }
  }
}
