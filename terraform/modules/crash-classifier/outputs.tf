output "name" {
  value       = azurerm_linux_function_app.crash_classifier.name
  description = "Crash classifier Function App name."
}

output "principal_id" {
  value       = azurerm_linux_function_app.crash_classifier.identity[0].principal_id
  description = "Classifier MI principal ID."
}
