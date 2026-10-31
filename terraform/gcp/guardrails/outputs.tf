# Outputs exist so the guardrail can be CONFIRMED rather than assumed, which given this
# repository's history with checks that agree with whoever wrote them is the whole point.
#
# `terraform apply` succeeding means the API accepted the request. It does not mean an email will
# arrive. The console link below is how that gets checked by a human once, and the budget's own
# resource name is what `make cost-check` can read back later.

output "budget_name" {
  description = "The budget's resource name, as the API stored it"
  value       = google_billing_budget.guardrail.name
}

output "budget_display_name" {
  value = google_billing_budget.guardrail.display_name
}

output "thresholds" {
  description = "Alert thresholds actually configured, read back from the resource"
  value       = [for r in google_billing_budget.guardrail.threshold_rules : r.threshold_percent]
}

output "verify_in_console" {
  description = "Open this and confirm the budget exists, its amount, and that the email target is you"
  value       = "https://console.cloud.google.com/billing/${var.billing_account}/budgets"
}

output "next" {
  value = <<-EOT
    The guardrail is applied. Two things before any cluster resource exists:

      1. Open the console link above and confirm the budget is there, the amount reads
         ${local.budget.currency} ${local.budget.amount_inr}, and the email recipient is an address you read.
         Terraform can only tell you the API accepted it.

      2. Pin the provider. `terraform init` has just written .terraform.lock.hcl with the exact
         google provider version and its hashes. Commit that file, then move the version into
         versions.tf as an exact pin, taken from the lock file:

           grep -A2 'provider "registry.terraform.io/hashicorp/google"' .terraform.lock.hcl

         The loose range in versions.tf exists only because the authoring environment could not
         reach the registry. Leaving it loose is how a provider upgrade arrives unannounced.
  EOT
}
