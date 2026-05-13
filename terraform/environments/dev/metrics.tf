# Consumer group for the metrics Function App. Separate group means the
# metrics app tracks its own EH offset independently of crash-classifier
# and telemetry-writer — lag in one does not affect the others.
resource "azurerm_eventhub_consumer_group" "metrics" {
  provider = azurerm.workload

  name                = "metrics"
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.telemetry.name
  resource_group_name = azurerm_resource_group.main.name
}

# Metrics Function App. No Cosmos, no Service Bus — reads EH only.
# Shares the Y1 Consumption plan; on Consumption, apps scale independently.
resource "azurerm_linux_function_app" "metrics" {
  provider = azurerm.workload

  name                = "func-${local.name_prefix}-metrics"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.functions.id

  storage_account_name       = azurerm_storage_account.main.name
  storage_account_access_key = azurerm_storage_account.main.primary_access_key

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.10"
    }

    application_insights_connection_string = azurerm_application_insights.main.connection_string
  }

  app_settings = {
    "EH_TELEMETRY__fullyQualifiedNamespace" = "${azurerm_eventhub_namespace.main.name}.servicebus.windows.net"
    "EH_TELEMETRY__credential"              = "managedidentity"

    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
    "AzureWebJobsFeatureFlags"       = "EnableWorkerIndexing"
  }

  lifecycle {
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE"],
    ]
  }

  tags = local.tags
}

# EH Data Receiver scoped to the telemetry hub — same scope as classifier.
resource "azurerm_role_assignment" "metrics_to_eh_receiver" {
  provider = azurerm.workload

  scope                = azurerm_eventhub.telemetry.id
  role_definition_name = "Azure Event Hubs Data Receiver"
  principal_id         = azurerm_linux_function_app.metrics.identity[0].principal_id
}

resource "azurerm_monitor_diagnostic_setting" "functions_metrics" {
  provider = azurerm.workload

  name                       = "diag-func-${local.name_prefix}-metrics"
  target_resource_id         = azurerm_linux_function_app.metrics.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "FunctionAppLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
