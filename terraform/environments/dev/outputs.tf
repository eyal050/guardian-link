output "postgres_fqdn" {
  value       = module.postgres.fqdn
  description = "Postgres Flexible Server FQDN for migration scripts."
}

output "postgres_admin_password" {
  value       = module.postgres.admin_password
  sensitive   = true
  description = "Postgres admin password (sensitive)."
}

output "postgres_notifier_password" {
  value       = module.postgres.notifier_password
  sensitive   = true
  description = "Postgres notifier app-user password (sensitive)."
}

output "app_insights_name" {
  value       = module.observability.app_insights_name
  description = "App Insights component name for release annotations."
}

output "resource_group_name" {
  value       = azurerm_resource_group.main.name
  description = "Workload resource group name for CLI commands."
}

output "func_telemetry_writer_name" {
  value       = module.functions.telemetry_writer_name
  description = "Telemetry writer Function App name."
}

output "func_crash_classifier_name" {
  value       = module.crash_classifier.name
  description = "Crash classifier Function App name."
}

output "func_notifier_name" {
  value       = azurerm_linux_function_app.notifier.name
  description = "Notifier Function App name."
}

output "func_metrics_name" {
  value       = azurerm_linux_function_app.metrics.name
  description = "Metrics Function App name."
}

output "container_app_ml_stub_name" {
  value       = module.ml_stub.container_app_name
  description = "ML stub Container App name."
}

output "acr_login_server" { value = module.ml_stub.acr_login_server }
output "acr_name"         { value = module.ml_stub.acr_name }
output "ml_stub_fqdn"     { value = module.ml_stub.ml_stub_fqdn }

output "aks_cluster_name" {
  value       = module.aks.cluster_name
  description = "AKS cluster name for az aks get-credentials."
}

output "consumer_identity_client_id" {
  value       = module.aks.consumer_identity_client_id
  description = "Client ID annotated on the consumer Kubernetes service account."
}

output "storage_blob_url" {
  value       = module.storage.main_primary_blob_endpoint
  description = "Primary blob endpoint for the consumer checkpoint store."
}

output "eventhub_fqdn" {
  value       = "${module.eventhubs.namespace_name}.servicebus.windows.net"
  description = "Event Hub namespace FQDN for the consumer."
}

output "eventhub_name" {
  value       = module.eventhubs.telemetry_hub_name
  description = "Event Hub name (telemetry)."
}

output "key_vault_name" {
  value       = module.keyvault.name
  description = "Key Vault name for the CSI driver SecretProviderClass."
}
