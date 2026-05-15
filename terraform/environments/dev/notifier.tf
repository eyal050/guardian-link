# Azure Communication Services: provides both SMS and email in a single
# resource. Connection string auth (via Key Vault) is used instead of
# MI auth — ACS does not expose granular data-plane RBAC roles for SMS
# sending that the Functions SDK can consume transparently.
resource "azurerm_communication_service" "main" {
  provider            = azurerm.workload
  name                = "acs-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  data_location       = "Europe"
  tags                = local.tags
}

# ACS Email Service: separate resource required for the email capability.
resource "azurerm_email_communication_service" "main" {
  provider            = azurerm.workload
  name                = "acs-email-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  data_location       = "Europe"
  tags                = local.tags
}

# Managed Azure domain (*.azurecomm.net). No custom domain needed in dev.
# After apply: manually link in portal → ACS resource → Email →
# Connect domain → select AzureManagedDomain.
resource "azurerm_email_communication_service_domain" "azure_managed" {
  provider          = azurerm.workload
  name              = "AzureManagedDomain"
  email_service_id  = azurerm_email_communication_service.main.id
  domain_management = "AzureManaged"
  tags              = local.tags
}

# ACS connection string in Key Vault. The notifier resolves this via a
# @Microsoft.KeyVault() reference in its app settings.
resource "azurerm_key_vault_secret" "acs_connection_string" {
  provider     = azurerm.workload
  name         = "acs-connection-string"
  value        = azurerm_communication_service.main.primary_connection_string
  key_vault_id = module.keyvault.id

  # depends_on removed during keyvault extraction; restored when notifier is modulized in Task 14 via terraform_data shim
}

# Notifier Function App. Shares the existing Consumption Y1 plan —
# on Consumption, shared-fate does not apply (apps scale independently).
# See crash-classifier.tf comment for full reasoning.
resource "azurerm_linux_function_app" "notifier" {
  provider = azurerm.workload

  name                = "func-${local.name_prefix}-notifier"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.functions.id

  storage_account_name       = module.storage.main_name
  storage_account_access_key = module.storage.main_primary_access_key

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.10"
    }
    application_insights_connection_string = module.observability.app_insights_connection_string
  }

  app_settings = {
    # SB identity-based trigger. 'SB_NAMESPACE' is the connection name
    # referenced in the @app.service_bus_queue_trigger decorator.
    "SB_NAMESPACE__fullyQualifiedNamespace" = "${azurerm_servicebus_namespace.main.name}.servicebus.windows.net"
    "SB_NAMESPACE__credential"              = "managedidentity"
    "SB_CRASH_QUEUE"                        = azurerm_servicebus_queue.crash_confirmed.name

    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
    "AzureWebJobsFeatureFlags"       = "EnableWorkerIndexing"

    "COSMOS_ENDPOINT"                = azurerm_cosmosdb_account.main.endpoint
    "COSMOS_DATABASE"                = azurerm_cosmosdb_sql_database.main.name
    "COSMOS_NOTIFICATIONS_CONTAINER" = azurerm_cosmosdb_sql_container.notifications.name

    # Key Vault references — resolved at runtime by the Function host once
    # notifier_to_kv_secrets_user RBAC propagates (30–60s after apply).
    "ACS_CONNECTION_STRING" = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.acs_connection_string.id})"
    "POSTGRES_PASSWORD"     = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.postgres_notifier_password.id})"

    # Set manually after apply (see post-apply checklist in the plan).
    "ACS_SENDER_PHONE" = "REPLACE_ME"
    "ACS_SENDER_EMAIL" = "REPLACE_ME"

    "POSTGRES_HOST" = azurerm_postgresql_flexible_server.main.fqdn
    "POSTGRES_USER" = "notifier"
    "POSTGRES_DB"   = azurerm_postgresql_flexible_server_database.guardianlink.name
  }

  lifecycle {
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE"],
      # These are set manually post-apply and must not be reset by TF.
      app_settings["ACS_SENDER_PHONE"],
      app_settings["ACS_SENDER_EMAIL"],
    ]
  }

  tags = local.tags
}

# SB Data Receiver scoped to the specific queue (not the namespace).
resource "azurerm_role_assignment" "notifier_to_sb_receiver" {
  provider = azurerm.workload

  scope                = azurerm_servicebus_queue.crash_confirmed.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_linux_function_app.notifier.identity[0].principal_id
}

# Cosmos Data Contributor — notifier reads + writes the notifications container.
# Account-level scope (same pattern as writer/classifier).
resource "random_uuid" "cosmos_notifier_role_assignment" {}

resource "azurerm_cosmosdb_sql_role_assignment" "notifier_to_cosmos_contributor" {
  provider = azurerm.workload

  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  name                = random_uuid.cosmos_notifier_role_assignment.result

  role_definition_id = "${azurerm_cosmosdb_account.main.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id       = azurerm_linux_function_app.notifier.identity[0].principal_id
  scope              = azurerm_cosmosdb_account.main.id
}

# Key Vault Secrets User — allows the Function host to resolve
# @Microsoft.KeyVault() references in app settings.
resource "azurerm_role_assignment" "notifier_to_kv_secrets_user" {
  provider = azurerm.workload

  scope                = module.keyvault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_function_app.notifier.identity[0].principal_id
}

resource "azurerm_monitor_diagnostic_setting" "functions_notifier" {
  provider = azurerm.workload

  name                       = "diag-func-${local.name_prefix}-notifier"
  target_resource_id         = azurerm_linux_function_app.notifier.id
  log_analytics_workspace_id = module.observability.workspace_id

  enabled_log {
    category = "FunctionAppLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
