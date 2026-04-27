output "postgres_fqdn" {
  value       = azurerm_postgresql_flexible_server.main.fqdn
  description = "Postgres Flexible Server FQDN for migration scripts."
}

output "postgres_admin_password" {
  value       = random_password.postgres_admin.result
  sensitive   = true
  description = "Postgres admin password (sensitive)."
}

output "postgres_notifier_password" {
  value       = random_password.postgres_notifier.result
  sensitive   = true
  description = "Postgres notifier app-user password (sensitive)."
}
