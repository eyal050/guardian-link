resource "grafana_data_source" "azure_monitor" {
  provider = grafana.managed

  type = "grafana-azure-monitor-datasource"
  name = "Azure Monitor"

  json_data_encoded = jsonencode({
    subscriptionId               = var.workload_subscription_id
    azureAuthType                = "msi"
    logAnalyticsDefaultWorkspace = azurerm_log_analytics_workspace.main.id
  })
}

resource "grafana_dashboard" "crash_pipeline" {
  provider = grafana.managed

  config_json = file("${path.module}/../../../dashboards/grafana/crash-pipeline.json")
  folder      = 0

  depends_on = [grafana_data_source.azure_monitor]
}
