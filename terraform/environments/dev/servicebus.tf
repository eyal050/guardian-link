# Service Bus namespace for the crash notification pipeline.
#
# Standard tier: required for queues with DLQ, sessions, and duplicate
# detection. Basic tier has none of those. Premium adds VNet/private
# endpoints and dedicated capacity — neither needed in dev.
#
# local_authentication_enabled = false: matches the identity-everywhere
# posture of the stack (Event Hubs, Cosmos, IoT Hub routing all use
# Entra ID). SAS keys would be a step backwards here.
resource "azurerm_servicebus_namespace" "main" {
  provider = azurerm.workload

  name                = "sbns-${local.name_prefix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name

  sku = "Standard"

  local_auth_enabled            = false
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true

  tags = local.tags
}

# crash-confirmed queue: the hardened delivery channel between the
# crash classifier and the notifier.
#
# lock_duration PT5M: the notifier has 5 minutes to complete all three
# notification channels (ACS SMS, SendGrid, Notification Hubs) and
# call Complete() before the broker redelivers. Generous — extend if
# the notifier fan-out ever blocks on slow third-party APIs.
#
# max_delivery_count 5: after 5 consecutive lock-expiry or Abandon()
# calls the broker moves the message to the DLQ automatically. Five
# retries before DLQ is the right balance between resilience and not
# hammering a broken third-party API forever.
#
# message_time_to_live P14D: crash events are potential safety evidence.
# 14 days in the queue before expiry gives ops time to drain a stuck
# notifier manually without losing the event. DLQ messages also get the
# same TTL.
#
# dead_lettering_on_message_expiration true: if a message somehow
# survives 14 days unprocessed, move it to the DLQ rather than silently
# discarding it. Keeps the audit trail intact.
#
# Partitioning not enabled: crash volume is single-digit per hour in
# dev and unlikely to exceed low hundreds in prod. Partitioning complicates
# DLQ inspection and ordering within a session. Skip it.
resource "azurerm_servicebus_queue" "crash_confirmed" {
  provider = azurerm.workload

  name         = "crash-confirmed"
  namespace_id = azurerm_servicebus_namespace.main.id

  lock_duration                        = "PT5M"
  max_delivery_count                   = 5
  default_message_ttl                  = "P14D"
  dead_lettering_on_message_expiration = true
}

# Crash-classifier consumer group on the telemetry Event Hub.
#
# The classifier reads the same 'telemetry' hub as the writer but on
# its own consumer group so the two functions track offsets independently.
# A crash_suspect event landing at offset N will be processed by both:
# - telemetry-writer: writes it to Cosmos + Blob (slice β)
# - crash-classifier: pulls the window from Cosmos, calls ML stub,
#   publishes to Service Bus if confidence >= 90%
# No shared state between the two groups; no ordering dependency.
resource "azurerm_eventhub_consumer_group" "crash_classifier" {
  provider = azurerm.workload

  name                = "crash-classifier"
  namespace_name      = module.eventhubs.namespace_name
  eventhub_name       = module.eventhubs.telemetry_hub_name
  resource_group_name = azurerm_resource_group.main.name
}

# Diagnostic settings for the Service Bus namespace.
#
# OperationalLogs: namespace/queue CRUD + config changes.
# RuntimeAuditLogs: authentication attempts (relevant: local auth disabled,
#   so a connection-string attempt will show up here as a 401 and alert us).
# VNetAndIPFilteringLogs omitted: no VNet/IP rules in dev.
resource "azurerm_monitor_diagnostic_setting" "servicebus_namespace" {
  provider = azurerm.workload

  name                       = "diag-sbns-${local.name_prefix}"
  target_resource_id         = azurerm_servicebus_namespace.main.id
  log_analytics_workspace_id = module.observability.workspace_id

  enabled_log {
    category = "OperationalLogs"
  }

  enabled_log {
    category = "RuntimeAuditLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
