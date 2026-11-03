# Outputs exist so the guardrail can be CONFIRMED rather than assumed - which, given this
# repository's history with checks that agree with whoever wrote them, is the whole point.
#
# `terraform apply` succeeding means the Budgets API accepted the request. It does not mean an
# email will arrive. On AWS that gap is wider than on GCP, because AWS notifies nobody by default:
# a budget with an unread address is indistinguishable from a working one until the day it matters.

output "budget_name" {
  description = "The budget's name, as the API stored it"
  value       = aws_budgets_budget.guardrail.name
}

output "budget_limit" {
  description = "Amount and currency read back from the resource, not from the config file"
  value       = "${aws_budgets_budget.guardrail.limit_amount} ${aws_budgets_budget.guardrail.limit_unit}"
}

output "thresholds" {
  description = "Alert thresholds actually configured, read back from the resource"
  # tostring before sort, because Terraform's sort() takes a list of STRINGS and `threshold` is a
  # number. Without it this fails at plan time with a type error about the list element, which
  # reads like a problem with the resource rather than with the function.
  value = sort([for n in aws_budgets_budget.guardrail.notification : tostring(n.threshold)])
}

output "verify_in_console" {
  description = "Open this and confirm the budget exists, its amount, and that the email target is you"
  # Account-scoped and global, hence no region in the URL - the same shape as the GCP billing
  # console link, and for the same reason.
  value = "https://us-east-1.console.aws.amazon.com/billing/home#/budgets"
}

output "next" {
  value = <<-EOT
    The guardrail is applied. Two things before any AWS resource exists:

      1. Open the console link above. Confirm the budget is there, the amount reads
         ${aws_budgets_budget.guardrail.limit_amount} ${aws_budgets_budget.guardrail.limit_unit}, and the email recipient is an address you read.
         Terraform can only tell you that the API accepted it, and on AWS that gap is wider
         than on GCP: Budgets notify NOBODY by default, so an unread address and a working
         one look identical until the day it matters.

      2. Pin the provider version and commit the lock file - versions.tf says why both:

           git add -f terraform/aws/guardrails/.terraform.lock.hcl

    WHAT YOU DO *NOT* HAVE TO DO, recorded because this note first said the opposite:

      The "Receive CloudWatch Billing Alerts" preference in Billing preferences is NOT a
      prerequisite for this budget. It governs whether estimated charges are published to
      CloudWatch as metric data, which is what a CloudWatch BILLING ALARM needs - a
      different mechanism from AWS Budgets, which emails its subscribers directly. An
      earlier draft of this output told you to go and enable it, asserting that cost alerts
      would not arrive otherwise. That was wrong, checked against AWS's own documentation,
      and corrected before it cost anyone a console trip.

      It is worth turning on anyway if you ever want a CloudWatch alarm, and it is one-way:
      data collection cannot be disabled afterwards.

    Then:  make aws-guardrails-verify
  EOT
}
