resource "azurerm_log_analytics_workspace" "main" {
  provider = azurerm.workload

  name                = "log-${local.name_prefix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name

  sku               = "PerGB2018"
  retention_in_days = 30

  tags = local.tags
}

resource "azurerm_application_insights" "main" {
  provider = azurerm.workload

  name                = "appi-${local.name_prefix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"

  tags = local.tags
}
