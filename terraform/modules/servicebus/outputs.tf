output "namespace_id" {
  value       = azurerm_servicebus_namespace.main.id
  description = "Service Bus namespace resource ID."
}

output "namespace_name" {
  value       = azurerm_servicebus_namespace.main.name
  description = "Service Bus namespace name."
}

output "crash_confirmed_queue_id" {
  value       = azurerm_servicebus_queue.crash_confirmed.id
  description = "crash-confirmed queue resource ID."
}

output "crash_confirmed_queue_name" {
  value       = azurerm_servicebus_queue.crash_confirmed.name
  description = "crash-confirmed queue name."
}
