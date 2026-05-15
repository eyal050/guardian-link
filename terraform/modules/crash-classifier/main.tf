# Crash-classifier Function App.
#
# Shares the Y1 Consumption plan with the telemetry-writer. On Consumption
# each app scales and bills independently — shared-fate only applies to
# dedicated/Premium plans where apps compete for pre-warmed instances.
# If this moves to Premium (e.g., for VNet integration), give it its own plan.
#
# Consumer group 'crash-classifier' on the telemetry Event Hub is declared
# in servicebus.tf alongside the rest of the classifier infrastructure.

resource "azurerm_linux_function_app" "crash_classifier" {
  provider = azurerm.workload

  name                = "func-${var.name_prefix}-crash-classifier"
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
    # EH identity-based trigger connection — same namespace as the writer
    # but the function body reads the 'crash-classifier' consumer group
    # (declared in function_app.py, must match the TF consumer group resource).
    "EH_TELEMETRY__fullyQualifiedNamespace" = "${var.eventhub_namespace_name}.servicebus.windows.net"
    "EH_TELEMETRY__credential"              = "managedidentity"

    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
    "AzureWebJobsFeatureFlags"       = "EnableWorkerIndexing"

    # Cosmos — read-only: the classifier fetches the telemetry window before
    # calling the ML endpoint. Auth is AAD via the MI's Data Reader role
    # (cosmos.tf has local_authentication_disabled=true).
    "COSMOS_ENDPOINT"  = var.cosmos_account_endpoint
    "COSMOS_DATABASE"  = var.cosmos_database_name
    "COSMOS_CONTAINER" = var.cosmos_telemetry_container_name

    # Service Bus sender — identity-based. The MI has Azure Service Bus Data
    # Sender scoped to the crash-confirmed queue (classifier_to_sb_sender below).
    # SB_NAMESPACE_FQDN is passed as a plain env var; the SDK's ServiceBusClient
    # takes fully_qualified_namespace directly (not the trigger __credential pattern).
    "SB_NAMESPACE_FQDN" = "${var.servicebus_namespace_name}.servicebus.windows.net"
    "SB_CRASH_QUEUE"    = var.servicebus_queue_name

    # Threshold and window size as config so they can be tuned without a redeploy.
    # 0.9 = architecture decision #11 (tolerate 10% false positives until model improves).
    "CLASSIFIER_CONFIDENCE_THRESHOLD" = "0.9"
    "TELEMETRY_WINDOW_SECONDS"        = "30"

    # ML stub Container App — see ml-stub.tf.
    # Pointing at /classify on the Container App; the Function's _call_ml()
    # falls back to the hardcoded stub only when this is empty.
    "ML_ENDPOINT_URL" = "https://${var.ml_stub_fqdn}/classify"
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

# EH Data Receiver — same hub as the writer, separate consumer group tracks
# offsets independently so classifier lag doesn't affect writer lag metrics.
resource "azurerm_role_assignment" "classifier_to_eh_receiver" {
  provider = azurerm.workload

  scope                = var.telemetry_hub_id
  role_definition_name = "Azure Event Hubs Data Receiver"
  principal_id         = azurerm_linux_function_app.crash_classifier.identity[0].principal_id
}

# Cosmos Data Reader (role id ...000001) — read-only. The classifier fetches
# the telemetry window but never writes. Least-privilege: grant reader not
# contributor (contrast with the writer which has ...000002 contributor).
resource "random_uuid" "cosmos_classifier_role_assignment" {}

resource "azurerm_cosmosdb_sql_role_assignment" "classifier_to_cosmos_reader" {
  provider = azurerm.workload

  resource_group_name = var.resource_group_name
  account_name        = var.cosmos_account_name
  name                = random_uuid.cosmos_classifier_role_assignment.result

  role_definition_id = "${var.cosmos_account_id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000001"
  principal_id       = azurerm_linux_function_app.crash_classifier.identity[0].principal_id
  scope              = var.cosmos_account_id
}

# Service Bus Data Sender scoped to the specific queue — not the namespace.
# The classifier MI can send to crash-confirmed and nothing else.
resource "azurerm_role_assignment" "classifier_to_sb_sender" {
  provider = azurerm.workload

  scope                = var.servicebus_queue_id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_linux_function_app.crash_classifier.identity[0].principal_id
}

resource "azurerm_monitor_diagnostic_setting" "functions_classifier" {
  provider = azurerm.workload

  name                       = "diag-func-${var.name_prefix}-classifier"
  target_resource_id         = azurerm_linux_function_app.crash_classifier.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "FunctionAppLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
