output "workspace_id" {
  value       = azurerm_log_analytics_workspace.main.id
  description = "Log Analytics workspace ID; passed to every diag setting in other modules."
}

output "workspace_name" {
  value       = azurerm_log_analytics_workspace.main.name
  description = "Log Analytics workspace name."
}

output "app_insights_id" {
  value       = azurerm_application_insights.main.id
  description = "App Insights resource ID."
}

output "app_insights_name" {
  value       = azurerm_application_insights.main.name
  description = "App Insights component name (used for release annotations + alerts scoping)."
}

output "app_insights_connection_string" {
  value       = azurerm_application_insights.main.connection_string
  sensitive   = true
  description = "Connection string for Function Apps and the KV-stored secret."
}
