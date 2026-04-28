resource "azurerm_consumption_budget_subscription" "main" {
  provider = azurerm.workload

  name            = "budget-${var.application_name}-${var.environment_name}"
  subscription_id = "/subscriptions/${var.workload_subscription_id}"

  amount     = var.budget_amount
  time_grain = "Monthly"

  time_period {
    start_date = "2026-04-01T00:00:00Z"
    end_date   = "2036-04-01T00:00:00Z"
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
