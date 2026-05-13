# Event Hubs namespace for the device-telemetry streaming backbone.
#
# local_authentication_enabled = false: producers/consumers authenticate
# via Entra ID (e.g., IoT Hub routes using system-assigned identity +
# Azure Event Hubs Data Sender role). No SAS keys to rotate or leak.
#
# Standard SKU is required for >1 consumer group and 7-day retention.
# Auto-inflate bounded at 2 TU to cap dev cost.
resource "azurerm_eventhub_namespace" "main" {
  provider = azurerm.workload

  name                = "evhns-${local.name_prefix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name

  sku                      = "Standard"
  capacity                 = 1
  auto_inflate_enabled     = true
  maximum_throughput_units = 2

  public_network_access_enabled = true
  local_authentication_enabled  = false
  minimum_tls_version           = "1.2"

  tags = local.tags
}

# Single hub for device telemetry. Partitioned by deviceId at the producer
# (IoT Hub route or Function); 4 partitions = 4 max parallel consumers per
# group. Partition count can grow but not shrink on Standard, so this is a
# sticky choice. 7-day retention supports classifier replay over a past
# window. No Capture: the telemetry-writer Function will write raw batches
# to Blob when that slice lands.
resource "azurerm_eventhub" "telemetry" {
  provider = azurerm.workload

  name                = "telemetry"
  namespace_name      = azurerm_eventhub_namespace.main.name
  resource_group_name = azurerm_resource_group.main.name

  partition_count   = 4
  message_retention = 7
}

# Route namespace (and hub-level, which bubbles up) logs + metrics to the
# shared Log Analytics workspace. Categories selected for this config:
# - OperationalLogs  : namespace/hub CRUD + config changes
# - AutoScaleLogs    : records every TU inflation event (auto_inflate_enabled)
# - RuntimeAuditLogs : authentication attempts (relevant: local auth disabled)
# - ArchiveLogs      : Capture-related; empty today, harmless when Capture lands
# Kafka/CMK/VNet categories omitted - not in use for this slice.
resource "azurerm_monitor_diagnostic_setting" "eventhub_namespace" {
  provider = azurerm.workload

  name                       = "diag-evhns-${local.name_prefix}"
  target_resource_id         = azurerm_eventhub_namespace.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "OperationalLogs"
  }

  enabled_log {
    category = "AutoScaleLogs"
  }

  enabled_log {
    category = "RuntimeAuditLogs"
  }

  enabled_log {
    category = "ArchiveLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# Consumer group for the local inspector consumer in apps/consumer/.
# Kept separate from any future telemetry-writer Function's group so
# multiple consumers can run without partition-ownership conflicts.
resource "azurerm_eventhub_consumer_group" "inspector" {
  provider = azurerm.workload

  name                = "inspector"
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.telemetry.name
  resource_group_name = azurerm_resource_group.main.name
}
