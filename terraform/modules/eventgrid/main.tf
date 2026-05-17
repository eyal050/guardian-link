# Custom topic for application-published lifecycle events
# (device.paired, user.created, etc.).
#
# local_auth_enabled = false: publishers authenticate via Entra ID
# (EventGrid Data Sender role), not access keys. No keys to rotate,
# no keys to leak into config.
#
# CloudEvents 1.0 schema — portable, CNCF standard.
#
# Azure *system* topics (blob-created, Key Vault events) are a separate
# resource (azurerm_eventgrid_system_topic) and will be added alongside
# the storage account / Key Vault that sources them.
resource "azurerm_eventgrid_topic" "lifecycle" {
  provider = azurerm.workload

  name                = "evgt-${var.name_prefix}-lifecycle"
  location            = var.location
  resource_group_name = var.resource_group_name

  input_schema                  = "CloudEventSchemaV1_0"
  local_auth_enabled            = false
  public_network_access_enabled = true

  tags = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "eventgrid_lifecycle" {
  provider = azurerm.workload

  name                       = "diag-evgt-${var.name_prefix}-lifecycle"
  target_resource_id         = azurerm_eventgrid_topic.lifecycle.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "DeliveryFailures"
  }

  enabled_log {
    category = "PublishFailures"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
