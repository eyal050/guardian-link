resource "azurerm_log_analytics_workspace" "main" {
  provider = azurerm.workload

  name                = "log-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name

  sku               = "PerGB2018"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

resource "azurerm_application_insights" "main" {
  provider = azurerm.workload

  name                = "appi-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"

  tags = var.tags
}
