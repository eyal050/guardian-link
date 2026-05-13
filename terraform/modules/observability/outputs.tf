output "workspace_id" {
  value       = azurerm_log_analytics_workspace.main.id
  description = "Log Analytics workspace resource ID — passed to diagnostic settings in other modules."
}

output "workspace_name" {
  value       = azurerm_log_analytics_workspace.main.name
  description = "Log Analytics workspace name."
}

output "app_insights_id" {
  value       = azurerm_application_insights.main.id
  description = "Application Insights resource ID."
}

output "app_insights_name" {
  value       = azurerm_application_insights.main.name
  description = "Application Insights component name, used for release annotations."
}

output "app_insights_connection_string" {
  value       = azurerm_application_insights.main.connection_string
  sensitive   = true
  description = "Connection string injected into Function App settings."
}

output "app_insights_instrumentation_key" {
  value       = azurerm_application_insights.main.instrumentation_key
  sensitive   = true
  description = "Instrumentation key for SDKs that don't support connection strings."
}
