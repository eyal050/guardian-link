output "namespace_id" {
  value       = azurerm_eventhub_namespace.main.id
  description = "Event Hub namespace resource ID."
}

output "namespace_name" {
  value       = azurerm_eventhub_namespace.main.name
  description = "Event Hub namespace name (used to build endpoint URIs)."
}

output "telemetry_hub_id" {
  value       = azurerm_eventhub.telemetry.id
  description = "Telemetry Event Hub resource ID — passed to IoT Hub routing module."
}

output "telemetry_hub_name" {
  value       = azurerm_eventhub.telemetry.name
  description = "Telemetry Event Hub name (entity path)."
}
