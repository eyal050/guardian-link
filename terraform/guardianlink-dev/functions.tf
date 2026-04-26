# Telemetry-writer Function App: Event-Hub-triggered Python function
# that consumes from the 'telemetry' hub and (in later slices) writes
# raw events to Blob + hot rows to Cosmos. THIS slice deploys the App
# + EH trigger wiring only — the function body just logs each event to
# App Insights so we can verify the identity-based EH trigger fires
# before adding any storage IO. Blob write lands in the next slice;
# Cosmos in a later one.

# Dedicated consumer group so the writer's offsets/lag are tracked
# independently of $Default and 'inspector'. Three consumer groups,
# one per role: $Default (unused, idiomatic to leave alone), inspector
# (apps/consumer debug tool), telemetry-writer (this Function).
resource "azurerm_eventhub_consumer_group" "telemetry_writer" {
  provider = azurerm.workload

  name                = "telemetry-writer"
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.telemetry.name
  resource_group_name = azurerm_resource_group.main.name
}

# Y1 (Consumption) Linux plan: scales to zero, cheapest fit for an EH-
# triggered writer running at dev volumes. Once the simulator is
# publishing the trigger keeps the worker warm; cold start only matters
# after long idle. Premium (EP1) would buy pre-warmed instances + VNet
# integration; neither is needed in dev.
resource "azurerm_service_plan" "functions" {
  provider = azurerm.workload

  name                = "plan-${local.name_prefix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name

  os_type  = "Linux"
  sku_name = "Y1"

  tags = local.tags
}

# Telemetry-writer Function App.
#
# storage_account_access_key (vs. identity-based AzureWebJobsStorage):
# identity-based host storage on Linux Consumption is officially
# supported with workarounds, but the Files content-share still needs
# a connection string. For dev cost + simplicity we reuse the existing
# storage account via shared key. shared_access_key_enabled on stgl* is
# true today; if the stack later moves to identity-only on storage, the
# writer needs to flip to a Premium/Flex Consumption plan or accept
# the documented Linux Consumption workaround.
#
# EH trigger uses an identity-based connection: the namespace has
# local_authentication_enabled=false, so connection-string auth would
# fail at runtime. The connection name 'EH_TELEMETRY' is referenced
# both in the trigger decorator (connection="EH_TELEMETRY" in
# function_app.py) and in the __fullyQualifiedNamespace / __credential
# app settings below — these three strings must agree.
resource "azurerm_linux_function_app" "telemetry_writer" {
  provider = azurerm.workload

  name                = "func-${local.name_prefix}-telemetry-writer"
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

    # AI conn string set via site_config (not app_settings) — the
    # provider normalizes here on read, so anchoring TF to the same
    # location avoids a perpetual diff.
    application_insights_connection_string = azurerm_application_insights.main.connection_string
  }

  app_settings = {
    # Identity-based connection for the EH trigger. The runtime reads
    # both __fullyQualifiedNamespace (where) and __credential (how).
    "EH_TELEMETRY__fullyQualifiedNamespace" = "${azurerm_eventhub_namespace.main.name}.servicebus.windows.net"
    "EH_TELEMETRY__credential"              = "managedidentity"

    # Run the Oryx build on deploy so pip installs requirements.txt
    # remotely. Without this, `az functionapp deployment source config-zip`
    # uploads the source verbatim and the worker can't import packages.
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"

    # v2 (decorator-based) Python model requires the host to index
    # functions inside the worker process. Newer 4.x runtimes default
    # this on, but some Linux Consumption images still need the flag
    # explicitly — without it the host returns zero discovered functions
    # even when function_app.py loads cleanly.
    "AzureWebJobsFeatureFlags" = "EnableWorkerIndexing"
  }

  # WEBSITE_RUN_FROM_PACKAGE is set by `az functionapp deployment source
  # config-zip` (uploads the zip to blob, writes the SAS URL here). It
  # changes on every deploy so TF must not manage it — without this
  # ignore, `terraform apply` would strip the URL and unload the
  # function.
  lifecycle {
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE"],
    ]
  }

  tags = local.tags
}

# Function MI needs read access to the telemetry hub. Scoped to the hub
# (not the namespace) — same least-privilege pattern as iot_to_eh_sender.
# RBAC propagation can take 30-60s on a fresh grant; first events after
# `terraform apply` may surface 401/403 in FunctionAppLogs until then.
resource "azurerm_role_assignment" "func_to_eh_receiver" {
  provider = azurerm.workload

  scope                = azurerm_eventhub.telemetry.id
  role_definition_name = "Azure Event Hubs Data Receiver"
  principal_id         = azurerm_linux_function_app.telemetry_writer.identity[0].principal_id
}

# Route Function App platform logs + metrics to LAW so trigger errors,
# host startup failures, and cold-start delays are queryable alongside
# the rest of the stack. FunctionAppLogs covers worker stdout/stderr
# and trigger lifecycle. AppServiceConsoleLogs / HTTPLogs / AuditLogs
# are not in scope for an EH-triggered writer with no HTTP surface.
resource "azurerm_monitor_diagnostic_setting" "functions_writer" {
  provider = azurerm.workload

  name                       = "diag-func-${local.name_prefix}-writer"
  target_resource_id         = azurerm_linux_function_app.telemetry_writer.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "FunctionAppLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
