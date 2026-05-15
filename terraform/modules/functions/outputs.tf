output "service_plan_id" {
  value       = azurerm_service_plan.functions.id
  description = "Shared Y1 plan ID — consumed by crash-classifier, notifier, metrics modules."
}

output "telemetry_writer_name" {
  value       = azurerm_linux_function_app.telemetry_writer.name
  description = "Function App name (used in dev outputs)."
}

output "telemetry_writer_principal_id" {
  value       = azurerm_linux_function_app.telemetry_writer.identity[0].principal_id
  description = "Writer MI principal — exposed for future RBAC grants from env root."
}
