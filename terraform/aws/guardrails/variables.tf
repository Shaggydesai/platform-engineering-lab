# Who gets the alarm emails.
#
# NO DEFAULT, AND THAT IS THE POINT. AWS Budgets notify nobody unless a subscriber is named - a
# notification block with an empty subscriber list is accepted by the API and silent forever. That
# is the opposite of GCP, where Cloud Billing emails the billing account's admins by default and
# the equivalent variable can safely default to empty.
#
# So a missing address must fail here rather than produce a budget that exists and watches nothing.
# Terraform would prompt interactively for an unset variable, which in a Makefile target reads like
# a hang, so `make aws-guardrails` checks for it first and refuses with the command to set it:
#
#   export TF_VAR_alert_emails='["you@example.com"]'
#
# It is kept OUT OF GIT the same way the GCP billing account ID is - persisted to
# .cache/aws-alert-email, which is gitignored - because this repository is public and an email
# address in a public repository is an address in a scraper's list.
variable "alert_emails" {
  description = "Email addresses AWS Budgets notifies when a threshold is crossed"
  type        = list(string)

  validation {
    condition     = length(var.alert_emails) > 0
    error_message = "At least one email address is required. AWS Budgets notify nobody by default, so a budget with no subscriber is a guardrail that cannot warn you."
  }

  validation {
    # Shape only, and deliberately loose: this catches the empty string and the obvious paste of a
    # name or an account ID. It cannot tell whether the address is one the operator reads, which is
    # why `make aws-guardrails` ends by saying to confirm that a test email arrives.
    condition     = alltrue([for e in var.alert_emails : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", e))])
    error_message = "Each entry must look like an email address - AWS rejects the budget otherwise, with an error about the notification rather than about the address."
  }
}

locals {
  # One source of truth, the same arrangement as the on-prem substrate's nodes.json (ADR-0008) and
  # the GCP substrate's cluster.json. Read rather than duplicated, so the budget amount cannot
  # disagree between this state and the cluster's, and so `make lint` can compare them.
  cfg    = jsondecode(file("${path.module}/../../../clusters/aws/cluster.json"))
  budget = local.cfg.budget
}
