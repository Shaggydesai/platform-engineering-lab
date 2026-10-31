# The billing account ID, e.g. 01A2B3-C4D5E6-F7G8H9.
#
# The ONLY input not read from clusters/gcp/cluster.json, and the reason is in that file: this
# repository is public, and while a billing account ID is not a credential it is the one value
# here that identifies a payment instrument.
#
#   export TF_VAR_billing_account="$(gcloud billing accounts list \
#     --format='value(name)' | head -1 | cut -d/ -f2)"
#
# `make gcp-guardrails` checks for it and refuses with that command rather than failing inside
# Terraform with a prompt nobody expected.
variable "billing_account" {
  description = "GCP billing account ID the budget is attached to (not a project)"
  type        = string

  validation {
    # Shape only: XXXXXX-XXXXXX-XXXXXX. This catches the two things people actually paste - a
    # project ID, and the full `billingAccounts/0123...` resource name - both of which Terraform
    # would otherwise send to the API and get back a permission error for, which reads like a
    # missing role rather than a wrong value.
    condition     = can(regex("^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$", var.billing_account))
    error_message = "Expected a bare billing account ID like 01A2B3-C4D5E6-F7G8H9 - not a project ID, and not the billingAccounts/... resource name."
  }
}

# Who gets the alert emails, beyond the billing account's own admins.
#
# Default empty on purpose: with no notification channels, Cloud Billing emails the billing
# account's admins and users, which on a personal account is the person reading this. Adding
# addresses here means creating Monitoring notification channels, which is a bigger change than
# the guardrail needs on day one.
variable "extra_notification_channels" {
  description = "Monitoring notification channel IDs to alert in addition to billing admins"
  type        = list(string)
  default     = []
}

locals {
  # One source of truth, the same arrangement as the on-prem substrate's nodes.json (ADR-0008).
  # Read rather than duplicated, so a zone or a budget amount cannot disagree between this state
  # and the cluster's.
  cfg    = jsondecode(file("${path.module}/../../../clusters/gcp/cluster.json"))
  budget = local.cfg.budget
}
