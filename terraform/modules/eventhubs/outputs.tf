output "namespace_id" {
  value       = azurerm_eventhub_namespace.main.id
  description = "EH namespace ID — Data Receiver scope for the AKS consumer."
}
output "namespace_name" {
  value       = azurerm_eventhub_namespace.main.name
  description = "EH namespace name — Function App __fullyQualifiedNamespace settings + IoT Hub endpoint URI."
}
output "telemetry_hub_id" {
  value       = azurerm_eventhub.telemetry.id
  description = "Telemetry hub ID — Data Sender (IoT Hub) and Data Receiver (Functions) RBAC scope."
}
output "telemetry_hub_name" {
  value       = azurerm_eventhub.telemetry.name
  description = "Telemetry hub name — IoT Hub endpoint entity_path."
}
output "inspector_consumer_group_name" {
  value       = azurerm_eventhub_consumer_group.inspector.name
  description = "Inspector consumer group name (apps/consumer)."
}
