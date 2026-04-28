# Subscription pre-exists; pipeline SP lacks Microsoft.Subscription/aliases/write
# (billing-level permission). Use removed block to drop it from state without
# destroying, and reference the subscription ID via var.workload_subscription_id.
removed {
  from = azurerm_subscription.main
  lifecycle {
    destroy = false
  }
}

resource "azurerm_management_group_subscription_association" "main" {
  count = var.management_group_id == null ? 0 : 1

  management_group_id = var.management_group_id
  subscription_id     = "/subscriptions/${var.workload_subscription_id}"
}
