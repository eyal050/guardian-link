output "acr_id" {
  value       = azurerm_container_registry.main.id
  description = "ACR ID — AKS kubelet AcrPull RBAC scope."
}
output "acr_name"         { value = azurerm_container_registry.main.name }
output "acr_login_server" { value = azurerm_container_registry.main.login_server }
output "ml_stub_fqdn" {
  value       = azurerm_container_app.ml_stub.latest_revision_fqdn
  description = "ML stub Container App FQDN — classifier ML_ENDPOINT_URL."
}
output "container_app_name" {
  value       = azurerm_container_app.ml_stub.name
  description = "ML stub Container App name."
}
