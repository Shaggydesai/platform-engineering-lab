terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # A BOUNDED RANGE FOR EXACTLY ONE `terraform init`, then pinned exactly - the same sequence
      # terraform/gcp/guardrails went through, and the same reason: the authoring environment
      # cannot reach registry.terraform.io, and three pins written from memory in this repository
      # have been wrong.
      #
      # The first `terraform init` on the laptop resolves a real version. THEN replace the range
      # with that exact version and commit the lock file - `make lint` starts enforcing the lock
      # the moment the version is exact, which is the self-closing rule ADR-0022's consequences
      # describe:
      #
      #   git add -f terraform/aws/.terraform.lock.hcl
      version = ">= 5.0.0, < 6.0.0"
    }
    http = {
      source = "hashicorp/http"
      # Used once, to ask AWS what this workstation's public address is so the security group can
      # admit it and nothing else. See variables.tf.
      version = ">= 3.4.0, < 4.0.0"
    }
  }
}

provider "aws" {
  region = local.cfg.region

  # NO access_key, NO secret_key, NO profile.
  #
  # Credentials come from the operator's own environment - `aws login --profile <name>` plus
  # AWS_PROFILE, which issues 12-hour browser-obtained credentials with nothing long-lived on
  # disk (ADR-0024). Hardcoding a profile name here would make this state work on one laptop;
  # hardcoding keys would put a long-lived credential in a public repository.
  #
  # A SESSION EXPIRES IN 12 HOURS and a cluster build takes minutes, so the failure mode is a
  # mid-apply expiry only if a session is left half-finished overnight. `aws login` again and
  # re-apply; Terraform is idempotent and will pick up where it stopped.

  default_tags {
    tags = {
      project    = "platform-engineering-lab"
      substrate  = "aws"
      managed_by = "terraform"
      # So `make cost-check` and a human in the console can both tell what this repository made
      # from what was already on the account - which matters more here than on GCP, because this
      # account is NOT a dedicated one. GCP gets a whole project per lab and can be deleted
      # wholesale (clusters/gcp/cluster.json); this account has two pre-existing IAM users and
      # whatever else, so tags are the only boundary there is.
      cluster = local.cfg.cluster_name
    }
  }
}
