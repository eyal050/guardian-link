resource "azurerm_subscription" "main" {
  subscription_name = var.new_subscription_name
  alias             = "${var.application_name}-${var.environment_name}"
  billing_scope_id  = var.billing_scope_id
}

resource "azurerm_management_group_subscription_association" "main" {
  count = var.management_group_id == null ? 0 : 1

  management_group_id = var.management_group_id
  subscription_id     = "/subscriptions/${azurerm_subscription.main.subscription_id}"
}
