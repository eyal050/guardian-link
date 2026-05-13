resource "azurerm_consumption_budget_subscription" "main" {
  provider = azurerm.workload

  name            = "budget-${var.application_name}-${var.environment_name}"
  subscription_id = "/subscriptions/${var.workload_subscription_id}"

  amount     = var.budget_amount
  time_grain = "Monthly"

  time_period {
    # formatdate always gives the first day of the current month so re-deploys
    # across month boundaries don't fail with "start date prior to current month".
    # ignore_changes prevents TF from updating this on every subsequent apply.
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
    end_date   = "2036-04-01T00:00:00Z"
  }

  lifecycle {
    ignore_changes = [time_period]
  }

  notification {
    enabled        = true
    threshold      = 50
    threshold_type = "Actual"
    operator       = "GreaterThan"
    contact_emails = [var.budget_contact_email]
  }

  notification {
    enabled        = true
    threshold      = 80
    threshold_type = "Forecasted"
    operator       = "GreaterThan"
    contact_emails = [var.budget_contact_email]
  }
}
