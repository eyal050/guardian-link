output "namespace_id" {
  value = azurerm_servicebus_namespace.main.id
}

output "namespace_name" {
  value = azurerm_servicebus_namespace.main.name
}

output "queue_id" {
  value = azurerm_servicebus_queue.crash_confirmed.id
}

output "queue_name" {
  value = azurerm_servicebus_queue.crash_confirmed.name
}

output "classifier_consumer_group_name" {
  value       = azurerm_eventhub_consumer_group.crash_classifier.name
  description = "Crash-classifier EH consumer group name."
}
