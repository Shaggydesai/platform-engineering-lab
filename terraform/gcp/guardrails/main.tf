# The ₹400 budget alert, and nothing else.
#
# A SEPARATE TERRAFORM STATE from the cluster, deliberately (ADR-0003 Decision 3). A guardrail
# applied in the same run as the thing it guards is not a guardrail: `terraform apply` creates
# resources in dependency order, and nothing makes the budget come first - so a cluster could
# exist for minutes, or for a whole failed apply, with no alert watching it.
#
# So this state holds one resource, is applied once, and is never destroyed by `make down`.

# THERE ARE NO google_project_service RESOURCES HERE, and that is a correction rather than an
# omission. Two of them lived here until 2026-10-31 and could never have worked.
#
# Terraform REFRESHES existing state before it plans. Refreshing `google_billing_budget` calls
# the Cloud Billing Budget API, and because the provider sets `billing_project`, that call is
# attributed to this project. So the refresh needs the API enabled - and the resource that would
# enable it has not been applied yet, because the plan it belongs to has not been produced yet.
# Refresh always precedes apply, so it never can be.
#
#     Error 403: Cloud Billing Budget API has not been used in project
#     platform-eng-lab-261031 before or it is disabled
#       ... while reading the budget that already exists
#
# The general rule, which is worth more than this instance: AN API THAT MUST EXIST BEFORE
# TERRAFORM CAN REFRESH ITS OWN STATE CANNOT BE MANAGED BY THAT TERRAFORM. Not "is awkward to" -
# cannot. Declaring it creates a state that cannot be read without the thing the state creates.
#
# So `make gcp-guardrails` enables all four with gcloud first: cloudresourcemanager and
# serviceusage (without which the provider cannot manage services at all), cloudbilling and
# billingbudgets (without which this file's one resource cannot be read). `gcloud services
# enable` is idempotent, so it is a second per run rather than a one-off someone must remember.
#
# It cost two failed applies to find, and only because the guardrail was pointed at a project
# created minutes earlier. Against shopverse-lab - years old, everything long since enabled -
# the original version applied first time and looked correct.

resource "google_billing_budget" "guardrail" {
  billing_account = var.billing_account
  display_name    = "platform-engineering-lab guardrail (${local.budget.currency} ${local.budget.amount_inr})"

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
