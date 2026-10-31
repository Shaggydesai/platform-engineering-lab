# The ₹400 budget alert, and nothing else.
#
# A SEPARATE TERRAFORM STATE from the cluster, deliberately (ADR-0003 Decision 3). A guardrail
# applied in the same run as the thing it guards is not a guardrail: `terraform apply` creates
# resources in dependency order, and nothing makes the budget come first - so a cluster could
# exist for minutes, or for a whole failed apply, with no alert watching it.
#
# So this state holds one resource, is applied once, and is never destroyed by `make down`.

# Enabling an API creates nothing billable, which is why this is allowed to come before the
# budget it is a prerequisite for. The chicken-and-egg is real but harmless: the Budget API must
# be on before a budget can be created, and turning it on costs nothing and nothing can run on it.
resource "google_project_service" "billingbudgets" {
  project = local.cfg.project_id
  service = "billingbudgets.googleapis.com"

  # Leave the API enabled when this state is destroyed. Disabling a service is slow, occasionally
  # fails, and can break things in the project that have nothing to do with this state - and the
  # thing being protected here is the ability to notice spending, which is not something to switch
  # off as a side effect of tidying up.
  disable_on_destroy = false
}

resource "google_project_service" "cloudbilling" {
  project            = local.cfg.project_id
  service            = "cloudbilling.googleapis.com"
  disable_on_destroy = false
}

resource "google_billing_budget" "guardrail" {
  billing_account = var.billing_account
  display_name    = "platform-engineering-lab guardrail (${local.budget.currency} ${local.budget.amount_inr})"

  depends_on = [
    google_project_service.billingbudgets,
    google_project_service.cloudbilling,
  ]

  # NO budget_filter, and that is the decision rather than an omission.
  #
  # A filter restricting this to one project would make the alert silent about any other project
  # on the account - including one created by hand during an experiment and forgotten, which is
  # precisely the spend this is meant to catch. Unfiltered means it watches everything the billing
  # account pays for.
  amount {
    specified_amount {
      currency_code = local.budget.currency
      # `units` is a whole-currency string. There is a `nanos` field for fractions and it is not
      # used: a budget of ₹400.00 is ₹400, and inventing precision here would just be noise.
      units = tostring(local.budget.amount_inr)
    }
  }

  # Three thresholds, from clusters/gcp/cluster.json so the numbers live in one place.
  #
  # 50% is the one that matters. At 90% the money is mostly spent; at 50% there is still time to
  # run `make down` and find out what is running. ADR-0003 asked for all three for that reason.
  dynamic "threshold_rules" {
    for_each = local.budget.thresholds
    content {
      threshold_percent = threshold_rules.value
      # CURRENT_SPEND, not FORECASTED_SPEND. A forecast alert on a lab that is deliberately
      # spiky - a cluster up for three hours, then nothing for a week - fires constantly and
      # teaches you to ignore it. What is wanted here is "you have actually spent this much".
      spend_basis = "CURRENT_SPEND"
    }
  }

  # all_updates_rule is present ONLY when channels are supplied. Left absent, Cloud Billing
  # emails the billing account's admins and users by default, which on a personal account is the
  # person who owns it - exactly what ADR-0003 asked for, with no Monitoring workspace, no
  # notification channel resources, and nothing else to keep working.
  #
  # Adding a channel later is additive: fill extra_notification_channels and re-apply.
  dynamic "all_updates_rule" {
    for_each = length(var.extra_notification_channels) > 0 ? [1] : []
    content {
      monitoring_notification_channels = var.extra_notification_channels
      # false: keep emailing the billing admins as well as the channels. Setting this true is how
      # someone ends up with alerts going only to a Slack webhook that was later deleted.
      disable_default_iam_recipients = false
    }
  }
}
