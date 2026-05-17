output "id" {
  value       = azurerm_key_vault.main.id
  description = "Key Vault resource ID — RBAC scope for Function MIs and AKS consumer identity."
}

output "name" {
  value       = azurerm_key_vault.main.name
  description = "Key Vault name (used by AKS CSI SecretProviderClass)."
}

output "operator_secrets_officer_role_assignment_id" {
  value       = azurerm_role_assignment.kv_operator_secrets_officer.id
  description = "depends_on target for downstream modules creating KV secrets during the same apply."
}

output "appi_connection_string_secret_id" {
  value       = azurerm_key_vault_secret.appi_connection_string.id
  description = "Versioned URI of the App Insights connection string secret."
}
