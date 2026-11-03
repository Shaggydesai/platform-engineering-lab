# The $5 budget alarm, and nothing else.
#
# A SEPARATE TERRAFORM STATE from the cluster, deliberately (ADR-0003 Decision 3) - the same
# arrangement as terraform/gcp/guardrails and for the same reason. A guardrail applied in the same
# run as the thing it guards is not a guardrail: `terraform apply` creates resources in dependency
# order, and nothing makes the budget come first, so a cluster could exist for minutes - or for a
# whole failed apply - with no alarm watching it.
#
# So this state holds one resource, is applied once, and is never destroyed by `make aws-down`.

# THERE IS NO API TO ENABLE FIRST, which is the one way this is simpler than GCP.
#
# terraform/gcp/guardrails/main.tf carries a long note about a chicken-and-egg problem: the Cloud
# Billing Budget API had to be enabled before Terraform could REFRESH the budget resource, so the
# resource that would enable it could never be applied first. AWS has no per-account service
# enablement, so that class of failure does not exist here.
#
# WHAT REPLACES IT IS A PERMISSION PROBLEM, and it is worth knowing before the first apply. Budgets
# are an account-level service: an IAM principal needs budgets:ModifyBudget (and ViewBudget to read
# it back), and on an account whose root user created an IAM user with a narrow policy, this is the
# step that fails. On a fresh personal account operating as the account owner it just works.

resource "aws_budgets_budget" "guardrail" {
  name = "platform-engineering-lab guardrail"

  budget_type = "COST"
  time_unit   = "MONTHLY"

  # Strings, not numbers, and that is the API's shape rather than Terraform's preference.
  # Read from clusters/aws/cluster.json so the amount lives in exactly one place and
  # `make aws-guardrails-verify` can compare what the API stored against what the file asks for.
  limit_amount = tostring(local.budget.amount_usd)
  limit_unit   = local.budget.currency

  # time_period_start is deliberately absent. Terraform defaults it to the first of the current
  # month, which is what a monthly budget means; pinning a date here would make the resource drift
  # the moment the month turned.

  # NO cost_filter, and that is the decision rather than an omission - the same one the GCP
  # guardrail makes in the same words.
  #
  # A filter restricting this to one service, tag or region would make the alarm silent about
  # everything else the account pays for, including a resource created by hand during an
  # experiment and forgotten. That is precisely the spend this exists to catch: the GCP billing
  # account turned out to be carrying ₹591 of charges from an abandoned project before this
  # repository had built anything, and a filtered budget would have said nothing.

  # Three thresholds, read from clusters/aws/cluster.json so the numbers live in one place.
  #
  # 50% is the one that matters. At 90% the money is mostly spent; at 50% there is still time to
  # run `make aws-down` and find out what is running. ADR-0003 asked for all three for that reason.
  dynamic "notification" {
    for_each = local.budget.thresholds
    content {
      # The file stores fractions (0.5) because that is what the GCP API takes; AWS wants percent.
      # Converted here rather than stored twice, so the two substrates cannot disagree about what
      # "the 50% threshold" is.
      threshold      = notification.value * 100
      threshold_type = "PERCENTAGE"

      comparison_operator = "GREATER_THAN"

      # ACTUAL, not FORECASTED - the same decision as the GCP budget's CURRENT_SPEND and for the
      # same reason. A forecast alarm on a lab that is deliberately spiky (a cluster up for three
      # hours, then nothing for a week) fires constantly and teaches you to ignore it. What is
      # wanted is "you have actually spent this much".
      notification_type = "ACTUAL"

      # AND THIS IS THE REAL DIFFERENCE FROM GCP, worth stating loudly because getting it wrong
      # produces a budget that exists and tells nobody.
      #
      # Cloud Billing emails the billing account's admins by DEFAULT, so the GCP guardrail can
      # leave notification channels empty and still reach a human. AWS BUDGETS NOTIFY NOBODY BY
      # DEFAULT: a notification block with no subscriber is accepted and silent. So the address is
      # required (see variables.tf - there is no default, on purpose), and the one thing that can
      # still be wrong is whether it is an address the operator actually reads.
      subscriber_email_addresses = var.alert_emails
    }
  }
}
