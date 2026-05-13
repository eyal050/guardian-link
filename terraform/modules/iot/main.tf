# IoT Hub: device ingestion, identity-based routing to Event Hubs.
# See docs/architecture.md — decision on IoT Hub vs raw Event Hubs.

resource "azurerm_iothub" "main" {
  provider = azurerm.workload

  name                = "iot-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name

  sku {
    name     = "F1"
    capacity = 1
  }

  local_authentication_enabled  = true
  public_network_access_enabled = true
  event_hub_partition_count     = 2

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

resource "azurerm_role_assignment" "iot_to_eh_sender" {
  provider = azurerm.workload

  scope                = var.eventhub_id
  role_definition_name = "Azure Event Hubs Data Sender"
  principal_id         = azurerm_iothub.main.identity[0].principal_id
}

resource "azurerm_iothub_endpoint_eventhub" "telemetry" {
  provider = azurerm.workload

  name                = "telemetry-eh"
  resource_group_name = var.resource_group_name
  iothub_id           = azurerm_iothub.main.id

  authentication_type = "identityBased"
  endpoint_uri        = "sb://${var.eventhub_namespace_name}.servicebus.windows.net"
  entity_path         = var.eventhub_name

  depends_on = [azurerm_role_assignment.iot_to_eh_sender]
}

resource "azurerm_iothub_route" "all_to_telemetry" {
  provider = azurerm.workload

  resource_group_name = var.resource_group_name
  iothub_name         = azurerm_iothub.main.name

  name           = "route-all-to-telemetry-eh"
  source         = "DeviceMessages"
  condition      = "true"
  endpoint_names = [azurerm_iothub_endpoint_eventhub.telemetry.name]
  enabled        = true
}

resource "azurerm_monitor_diagnostic_setting" "iothub" {
  provider = azurerm.workload

  name                       = "diag-iot-${var.name_prefix}"
  target_resource_id         = azurerm_iothub.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "Connections" }
  enabled_log { category = "DeviceTelemetry" }
  enabled_log { category = "Routes" }
  enabled_log { category = "DeviceIdentityOperations" }
  metric { category = "AllMetrics"; enabled = true }
}
