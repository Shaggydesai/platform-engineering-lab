terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # EXACT, AND READ FROM A REAL RESOLUTION rather than from memory. This was a bounded range
      # for exactly one `terraform init`: the authoring environment cannot reach
      # registry.terraform.io, and three pins written from memory in this repository have been
      # wrong. That init ran on the laptop on 2026-11-05 and resolved 5.100.0.
      #
      # .terraform.lock.hcl carries the provider's HASHES and is the stronger pin - a re-published
      # 5.100.0 would fail verification rather than install quietly - so `make lint` now DEMANDS
      # it, because the version here is exact. That is the self-closing rule: pinning is what
      # turns a missing lock file from "expected" into a failure.
      #
      #   git add -f terraform/aws/guardrails/.terraform.lock.hcl
      #
      # Two of four Terraform states had no committed lock file on 2026-11-01 - a rule stated in
      # one comment and enforced nowhere.
      version = "5.100.0"
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
