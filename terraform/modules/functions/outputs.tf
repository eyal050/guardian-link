output "telemetry_writer_name" {
  value       = azurerm_linux_function_app.telemetry_writer.name
  description = "Telemetry writer Function App name."
}

output "telemetry_writer_principal_id" {
  value       = azurerm_linux_function_app.telemetry_writer.identity[0].principal_id
  description = "Telemetry writer managed identity principal ID."
}

output "crash_classifier_name" {
  value       = azurerm_linux_function_app.crash_classifier.name
  description = "Crash classifier Function App name."
}

output "crash_classifier_principal_id" {
  value       = azurerm_linux_function_app.crash_classifier.identity[0].principal_id
  description = "Crash classifier managed identity principal ID."
}

output "notifier_name" {
  value       = azurerm_linux_function_app.notifier.name
  description = "Notifier Function App name."
}

output "notifier_principal_id" {
  value       = azurerm_linux_function_app.notifier.identity[0].principal_id
  description = "Notifier managed identity principal ID."
}

output "metrics_name" {
  value       = azurerm_linux_function_app.metrics.name
  description = "Metrics Function App name."
}

output "metrics_principal_id" {
  value       = azurerm_linux_function_app.metrics.identity[0].principal_id
  description = "Metrics managed identity principal ID."
}
