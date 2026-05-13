resource "azurerm_resource_group" "main" {
  provider = azurerm.workload

  name     = "rg-${var.new_subscription_name}"
  location = var.primary_location
  tags     = local.tags
}
