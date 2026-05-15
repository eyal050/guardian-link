# Consumer group for the metrics Function App. Separate group means the
# metrics app tracks its own EH offset independently of crash-classifier
# and telemetry-writer — lag in one does not affect the others.
resource "azurerm_eventhub_consumer_group" "metrics" {
  provider = azurerm.workload

  name                = "metrics"
  namespace_name      = var.eventhub_namespace_name
  eventhub_name       = var.eventhub_name
  resource_group_name = var.resource_group_name
}

# Metrics Function App. No Cosmos, no Service Bus — reads EH only.
# Shares the Y1 Consumption plan; on Consumption, apps scale independently.
resource "azurerm_linux_function_app" "metrics" {
  provider = azurerm.workload

  name                = "func-${var.name_prefix}-metrics"
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = var.service_plan_id

  storage_account_name       = var.storage_account_name
  storage_account_access_key = var.storage_account_primary_access_key

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.10"
    }

    application_insights_connection_string = var.app_insights_connection_string
  }

  app_settings = {
    "EH_TELEMETRY__fullyQualifiedNamespace" = "${var.eventhub_namespace_name}.servicebus.windows.net"
    "EH_TELEMETRY__credential"              = "managedidentity"

    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
    "AzureWebJobsFeatureFlags"       = "EnableWorkerIndexing"
  }

  lifecycle {
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE"],
      # Set by the deployment pipeline post-release; both casings exist for legacy reasons.
      app_settings["DEPLOY_VERSION"],
      app_settings["deploy-version"],
      # Pipeline also stamps the deploy version as a tag.
      tags["deploy-version"],
    ]
  }

  tags = var.tags
}

# EH Data Receiver scoped to the telemetry hub — same scope as classifier.
resource "azurerm_role_assignment" "metrics_to_eh_receiver" {
  provider = azurerm.workload

  scope                = var.telemetry_hub_id
  role_definition_name = "Azure Event Hubs Data Receiver"
  principal_id         = azurerm_linux_function_app.metrics.identity[0].principal_id
}

resource "azurerm_monitor_diagnostic_setting" "functions_metrics" {
  provider = azurerm.workload

  name                       = "diag-func-${var.name_prefix}-metrics"
  target_resource_id         = azurerm_linux_function_app.metrics.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "FunctionAppLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
