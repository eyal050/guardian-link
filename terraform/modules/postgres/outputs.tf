output "fqdn" {
  value       = azurerm_postgresql_flexible_server.main.fqdn
  description = "Postgres FQDN."
}

output "database_name" {
  value       = azurerm_postgresql_flexible_server_database.guardianlink.name
  description = "Database name."
}

output "admin_password" {
  value       = random_password.postgres_admin.result
  sensitive   = true
  description = "Admin password (sensitive)."
}

output "notifier_password" {
  value       = random_password.postgres_notifier.result
  sensitive   = true
  description = "Notifier app-user password (sensitive)."
}

output "notifier_password_secret_id" {
  value       = azurerm_key_vault_secret.postgres_notifier_password.id
  description = "Versioned KV secret URI for notifier @Microsoft.KeyVault() reference."
}
