# IoT Hub terminates device connections (MQTT/AMQP over TLS) and routes
# every device-to-cloud message to the telemetry Event Hub via its own
# system-assigned managed identity.
#
# F1 (Free) SKU: feature-complete (twin, C2D, X.509, routing, MI) but
# capped at 8000 msgs/day and exactly one instance per Azure subscription.
# Plenty for simulator-scale dev; interview talking point for prod sizing.
#
# local_authentication_enabled = true: SAS device tokens remain accepted
# so the future simulator can connect with a device connection string.
# X.509-only hardening is deferred to the simulator slice when a device
# CA / cert story is in scope.
#
# event_hub_partition_count applies to the built-in 'events' endpoint.
# Since the route below sends everything to the external telemetry hub,
# the built-in endpoint only receives unmatched-fallback traffic. Set
# to the F1 minimum.
resource "azurerm_iothub" "main" {
  provider = azurerm.workload

  name                = "iot-${local.name_prefix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name

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

  tags = local.tags
}

# IoT Hub's system identity needs Send permission on the telemetry hub
# so the identity-based route below can publish messages without SAS.
# Scoped to the hub (not the namespace) for least privilege.
resource "azurerm_role_assignment" "iot_to_eh_sender" {
  provider = azurerm.workload

  scope                = azurerm_eventhub.telemetry.id
  role_definition_name = "Azure Event Hubs Data Sender"
  principal_id         = azurerm_iothub.main.identity[0].principal_id
}

# Identity-based routing endpoint pointing at the telemetry hub.
# 'identityBased' + no explicit identity_id means IoT Hub authenticates
# with its own system-assigned identity. Requires Data Sender role on
# the target hub to already exist at create time - hence depends_on.
resource "azurerm_iothub_endpoint_eventhub" "telemetry" {
  provider = azurerm.workload

  name                = "telemetry-eh"
  resource_group_name = azurerm_resource_group.main.name
  iothub_id           = azurerm_iothub.main.id

  authentication_type = "identityBased"
  endpoint_uri        = "sb://${azurerm_eventhub_namespace.main.name}.servicebus.windows.net"
  entity_path         = azurerm_eventhub.telemetry.name

  depends_on = [azurerm_role_assignment.iot_to_eh_sender]
}

# Route every device-to-cloud message to the telemetry endpoint.
# source=DeviceMessages + condition=true matches all D2C traffic;
# crash-suspect discrimination happens downstream at the classifier,
# not at ingest (docs/architecture.md decision #7).
#
# No explicit fallback_route: Azure's implicit fallback (to the
# built-in 'events' endpoint) stays enabled. With condition=true
# matching everything first, the fallback is moot in practice.
resource "azurerm_iothub_route" "all_to_telemetry" {
  provider = azurerm.workload

  resource_group_name = azurerm_resource_group.main.name
  iothub_name         = azurerm_iothub.main.name

  name           = "route-all-to-telemetry-eh"
  source         = "DeviceMessages"
  condition      = "true"
  endpoint_names = [azurerm_iothub_endpoint_eventhub.telemetry.name]
  enabled        = true
}

# Send IoT Hub logs + metrics to the shared Log Analytics workspace.
# Categories selected for what this slice actually exercises:
# - Connections             : device connect/disconnect + auth outcomes
# - DeviceTelemetry         : D2C message flow into the hub
# - Routes                  : route delivery attempts + failures.
#                             Critical for this slice - any breakage in
#                             the MI-based endpoint surfaces here.
# - DeviceIdentityOperations: registry changes (useful when devices arrive)
# Kafka / twin / jobs / direct methods categories omitted - not used yet.
resource "azurerm_monitor_diagnostic_setting" "iothub" {
  provider = azurerm.workload

  name                       = "diag-iot-${local.name_prefix}"
  target_resource_id         = azurerm_iothub.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "Connections"
  }

  enabled_log {
    category = "DeviceTelemetry"
  }

  enabled_log {
    category = "Routes"
  }

  enabled_log {
    category = "DeviceIdentityOperations"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
