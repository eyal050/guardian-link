resource "azurerm_dashboard_grafana" "main" {
  provider = azurerm.workload

  name                  = "amg-${local.name_prefix}"
  resource_group_name   = azurerm_resource_group.main.name
  location              = var.primary_location
  sku                   = "Standard"
  grafana_major_version = 11

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

resource "azurerm_role_assignment" "grafana_admin" {
  provider             = azurerm.workload
  scope                = azurerm_dashboard_grafana.main.id
  role_definition_name = "Grafana Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "grafana_viewer" {
  provider             = azurerm.workload
  count                = var.grafana_viewer_principal_id != null ? 1 : 0
  scope                = azurerm_dashboard_grafana.main.id
  role_definition_name = "Grafana Viewer"
  principal_id         = var.grafana_viewer_principal_id
}

resource "azurerm_role_assignment" "grafana_mon_reader" {
  provider             = azurerm.workload
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_dashboard_grafana.main.identity[0].principal_id
}
