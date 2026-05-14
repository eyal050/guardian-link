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

output "app_insights_name" {
  value       = azurerm_application_insights.main.name
  description = "App Insights component name for release annotations."
}

output "resource_group_name" {
  value       = azurerm_resource_group.main.name
  description = "Workload resource group name for CLI commands."
}

output "func_telemetry_writer_name" {
  value       = azurerm_linux_function_app.telemetry_writer.name
  description = "Telemetry writer Function App name."
}

output "func_crash_classifier_name" {
  value       = azurerm_linux_function_app.crash_classifier.name
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
  value       = azurerm_container_app.ml_stub.name
  description = "ML stub Container App name."
}

output "grafana_endpoint" {
  value       = azurerm_dashboard_grafana.main.endpoint
  description = "Azure Managed Grafana HTTPS endpoint."
}

output "aks_cluster_name" {
  value       = module.aks.cluster_name
  description = "AKS cluster name for az aks get-credentials."
}

output "consumer_identity_client_id" {
  value       = module.aks.consumer_identity_client_id
  description = "Client ID annotated on the consumer Kubernetes service account."
}

output "storage_blob_url" {
  value       = azurerm_storage_account.main.primary_blob_endpoint
  description = "Primary blob endpoint for the consumer checkpoint store."
}

output "eventhub_fqdn" {
  value       = "${azurerm_eventhub_namespace.main.name}.servicebus.windows.net"
  description = "Event Hub namespace FQDN for the consumer."
}

output "eventhub_name" {
  value       = azurerm_eventhub.telemetry.name
  description = "Event Hub name (telemetry)."
}

output "key_vault_name" {
  value       = azurerm_key_vault.main.name
  description = "Key Vault name for the CSI driver SecretProviderClass."
}
