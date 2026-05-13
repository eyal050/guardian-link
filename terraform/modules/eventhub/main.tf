# Event Hubs namespace and telemetry hub.
# RBAC-only auth (local_authentication_enabled = false).
# See docs/architecture.md — decision on three-way eventing split.

resource "azurerm_eventhub_namespace" "main" {
  provider = azurerm.workload

  name                = "evhns-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  capacity            = 1

  local_authentication_enabled = false

  tags = var.tags
}

resource "azurerm_eventhub" "telemetry" {
  provider = azurerm.workload

  name                = "evh-${var.name_prefix}-telemetry"
  namespace_id        = azurerm_eventhub_namespace.main.id
  partition_count     = var.partition_count
  message_retention   = var.message_retention_days
}

resource "azurerm_monitor_diagnostic_setting" "eventhub_ns" {
  provider = azurerm.workload

  name                       = "diag-evhns-${var.name_prefix}"
  target_resource_id         = azurerm_eventhub_namespace.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "ArchiveLogs" }
  enabled_log { category = "OperationalLogs" }
  metric { category = "AllMetrics"; enabled = true }
}
