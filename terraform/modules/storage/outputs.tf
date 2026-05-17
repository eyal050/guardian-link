output "main_id" {
  value       = azurerm_storage_account.main.id
  description = "Operational SA resource ID (consumer + writer RBAC scope)."
}
output "main_name" {
  value       = azurerm_storage_account.main.name
  description = "Operational SA name (Function App content share)."
}
output "main_primary_blob_endpoint" {
  value       = azurerm_storage_account.main.primary_blob_endpoint
  description = "Operational SA primary blob endpoint."
}
output "main_primary_access_key" {
  value       = azurerm_storage_account.main.primary_access_key
  sensitive   = true
  description = "Operational SA shared key — Function App content share auth."
}
output "raw_archive_id" {
  value       = azurerm_storage_account.raw_archive.id
  description = "Raw archive SA resource ID (writer Blob Data Contributor scope)."
}
output "raw_archive_primary_blob_endpoint" {
  value       = azurerm_storage_account.raw_archive.primary_blob_endpoint
  description = "Raw archive SA blob endpoint."
}
output "telemetry_raw_container_name" {
  value       = azurerm_storage_container.telemetry_raw.name
  description = "NDJSON archive container name."
}
output "eh_checkpoints_container_name" {
  value       = azurerm_storage_container.eh_checkpoints.name
  description = "Event Hub consumer checkpoint container name."
}
