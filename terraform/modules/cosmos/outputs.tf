output "account_id" {
  value       = azurerm_cosmosdb_account.main.id
  description = "Cosmos account ID — used as Cosmos SQL role assignment scope and for role_definition_id construction."
}
output "account_endpoint" {
  value       = azurerm_cosmosdb_account.main.endpoint
  description = "Cosmos account endpoint URL — Function App settings."
}
output "account_name" {
  value       = azurerm_cosmosdb_account.main.name
  description = "Cosmos account name — required by azurerm_cosmosdb_sql_role_assignment."
}
output "database_name" {
  value       = azurerm_cosmosdb_sql_database.main.name
  description = "Database name — Function App settings."
}
output "telemetry_container_name" {
  value       = azurerm_cosmosdb_sql_container.telemetry.name
  description = "Telemetry container name."
}
output "notifications_container_name" {
  value       = azurerm_cosmosdb_sql_container.notifications.name
  description = "Notifications container name."
}
