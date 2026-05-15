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
  namespace_name      = var.eventhub_namespace_name
  eventhub_name       = var.telemetry_hub_name
  resource_group_name = var.resource_group_name
}

# Y1 (Consumption) Linux plan: scales to zero, cheapest fit for an EH-
# triggered writer running at dev volumes. Once the simulator is
# publishing the trigger keeps the worker warm; cold start only matters
# after long idle. Premium (EP1) would buy pre-warmed instances + VNet
# integration; neither is needed in dev.
resource "azurerm_service_plan" "functions" {
  provider = azurerm.workload

  name                = "plan-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name

  os_type  = "Linux"
  sku_name = "Y1"

  tags = var.tags
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

  name                = "func-${var.name_prefix}-telemetry-writer"
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = azurerm_service_plan.functions.id

  storage_account_name       = var.storage_account_name
  storage_account_access_key = var.storage_account_primary_access_key

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
    application_insights_connection_string = var.app_insights_connection_string
  }

  app_settings = {
    # Identity-based connection for the EH trigger. The runtime reads
    # both __fullyQualifiedNamespace (where) and __credential (how).
    "EH_TELEMETRY__fullyQualifiedNamespace" = "${var.eventhub_namespace_name}.servicebus.windows.net"
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

    # Cosmos coordinates for the writer. Endpoint is non-secret;
    # auth is identity-based via DefaultAzureCredential resolving
    # the Function App's system-assigned MI (cosmos.tf has
    # local_authentication_disabled=true, so connection-string auth
    # would fail at the data plane).
    "COSMOS_ENDPOINT"  = var.cosmos_account_endpoint
    "COSMOS_DATABASE"  = var.cosmos_database_name
    "COSMOS_CONTAINER" = var.cosmos_telemetry_container_name

    # Raw-archive Blob target for slice β. Identity-based:
    # DefaultAzureCredential resolves the Function App's MI and the
    # 'Storage Blob Data Contributor' assignment on the archive
    # account (`func_to_blob_archive` below) authorizes the writes.
    # ACCOUNT is the full primary_blob_endpoint URL (the SDK's
    # BlobServiceClient takes account_url, not just the FQDN).
    "BLOB_ARCHIVE_ACCOUNT"   = var.raw_archive_blob_endpoint
    "BLOB_ARCHIVE_CONTAINER" = var.raw_archive_container_name
  }

  # WEBSITE_RUN_FROM_PACKAGE is set by `az functionapp deployment source
  # config-zip` (uploads the zip to blob, writes the SAS URL here). It
  # changes on every deploy so TF must not manage it — without this
  # ignore, `terraform apply` would strip the URL and unload the
  # function.
  lifecycle {
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE"],
      # Deployment pipeline writes these via `az functionapp config appsettings set`
      # after each release. Both casings exist for legacy reasons.
      app_settings["DEPLOY_VERSION"],
      app_settings["deploy-version"],
      # Pipeline also stamps the deploy version as a tag.
      tags["deploy-version"],
    ]
  }

  tags = var.tags
}

# Function MI needs read access to the telemetry hub. Scoped to the hub
# (not the namespace) — same least-privilege pattern as iot_to_eh_sender.
# RBAC propagation can take 30-60s on a fresh grant; first events after
# `terraform apply` may surface 401/403 in FunctionAppLogs until then.
resource "azurerm_role_assignment" "func_to_eh_receiver" {
  provider = azurerm.workload

  scope                = var.telemetry_hub_id
  role_definition_name = "Azure Event Hubs Data Receiver"
  principal_id         = azurerm_linux_function_app.telemetry_writer.identity[0].principal_id
}

# Cosmos data-plane RBAC. The 'Cosmos DB Built-in Data Contributor' role
# (well-known role definition id ...000002) grants read + write on data;
# the Cosmos control plane (account/database/container CRUD) is a
# separate Azure RBAC surface that we don't grant the Function. Account-
# level scope is fine here — the writer needs to write to one container
# today and may add others (raw events, crash events) without an RBAC
# round-trip. Narrow to /dbs/<db>/colls/<coll> if least-privilege grows
# important.
#
# A random_uuid for the assignment 'name' so plans are stable across
# applies; Cosmos requires the assignment ID to be a UUID (it's not the
# role being assigned, that's role_definition_id).
resource "random_uuid" "cosmos_writer_role_assignment" {}

resource "azurerm_cosmosdb_sql_role_assignment" "func_to_cosmos_writer" {
  provider = azurerm.workload

  resource_group_name = var.resource_group_name
  account_name        = var.cosmos_account_name
  name                = random_uuid.cosmos_writer_role_assignment.result

  role_definition_id = "${var.cosmos_account_id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id       = azurerm_linux_function_app.telemetry_writer.identity[0].principal_id
  scope              = var.cosmos_account_id
}

# Slice β: raw archive write path. 'Storage Blob Data Contributor'
# scoped to the archive SA — single-container account today, narrow
# to container scope when more containers exist. RBAC propagation is
# 30-60s the first time; expect the writer to log 403 on the initial
# upload attempts after a fresh apply.
resource "azurerm_role_assignment" "func_to_blob_archive" {
  provider = azurerm.workload

  scope                = var.raw_archive_storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_function_app.telemetry_writer.identity[0].principal_id
}

# Route Function App platform logs + metrics to LAW so trigger errors,
# host startup failures, and cold-start delays are queryable alongside
# the rest of the stack. FunctionAppLogs covers worker stdout/stderr
# and trigger lifecycle. AppServiceConsoleLogs / HTTPLogs / AuditLogs
# are not in scope for an EH-triggered writer with no HTTP surface.
resource "azurerm_monitor_diagnostic_setting" "functions_writer" {
  provider = azurerm.workload

  name                       = "diag-func-${var.name_prefix}-writer"
  target_resource_id         = azurerm_linux_function_app.telemetry_writer.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "FunctionAppLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
