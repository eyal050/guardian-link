# Service Bus namespace and crash-confirmed queue.
# at-least-once + DLQ semantics for the crash notification pipeline.
# RBAC-only auth (local_authentication_enabled = false).
# See docs/architecture.md — decision on three-way eventing split.

resource "azurerm_servicebus_namespace" "main" {
  provider = azurerm.workload

  name                = "sbns-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"

  local_authentication_enabled = false

  tags = var.tags
}

resource "azurerm_servicebus_queue" "crash_confirmed" {
  provider = azurerm.workload

  name         = "crash-confirmed"
  namespace_id = azurerm_servicebus_namespace.main.id

  lock_duration                = var.lock_duration
  max_delivery_count           = var.max_delivery_count
  default_message_ttl          = var.message_ttl
  dead_lettering_on_message_expiration = true
  requires_duplicate_detection = false
  partitioning_enabled         = false
}

resource "azurerm_monitor_diagnostic_setting" "servicebus_ns" {
  provider = azurerm.workload

  name                       = "diag-sbns-${var.name_prefix}"
  target_resource_id         = azurerm_servicebus_namespace.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "OperationalLogs" }
  enabled_log { category = "VNetAndIPFilteringLogs" }
  metric { category = "AllMetrics"; enabled = true }
}
