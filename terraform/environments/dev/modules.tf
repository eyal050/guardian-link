# Per-component module instantiations. See terraform/modules/<name>/ for definitions.
# Populated incrementally; a corresponding dev/<name>.tf is deleted as each module lands.

module "observability" {
  source = "../../modules/observability"
  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix         = local.name_prefix
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

module "storage" {
  source = "../../modules/storage"
  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                = local.name_prefix
  environment_name           = var.environment_name
  location                   = var.primary_location
  resource_group_name        = azurerm_resource_group.main.name
  log_analytics_workspace_id = module.observability.workspace_id
  tags                       = local.tags
}

module "keyvault" {
  source = "../../modules/keyvault"
  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                    = local.name_prefix
  location                       = var.primary_location
  resource_group_name            = azurerm_resource_group.main.name
  app_insights_connection_string = module.observability.app_insights_connection_string
  tags                           = local.tags
}

module "cosmos" {
  source = "../../modules/cosmos"
  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                = local.name_prefix
  location                   = var.primary_location
  resource_group_name        = azurerm_resource_group.main.name
  log_analytics_workspace_id = module.observability.workspace_id
  tags                       = local.tags
}

module "eventhubs" {
  source = "../../modules/eventhubs"
  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                = local.name_prefix
  location                   = var.primary_location
  resource_group_name        = azurerm_resource_group.main.name
  log_analytics_workspace_id = module.observability.workspace_id
  tags                       = local.tags
}

module "servicebus" {
  source = "../../modules/servicebus"
  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                = local.name_prefix
  location                   = var.primary_location
  resource_group_name        = azurerm_resource_group.main.name
  log_analytics_workspace_id = module.observability.workspace_id
  eventhub_namespace_name    = module.eventhubs.namespace_name
  eventhub_name              = module.eventhubs.telemetry_hub_name
  tags                       = local.tags
}

module "iot" {
  source = "../../modules/iot"
  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                = local.name_prefix
  location                   = var.primary_location
  resource_group_name        = azurerm_resource_group.main.name
  log_analytics_workspace_id = module.observability.workspace_id
  eventhub_namespace_name    = module.eventhubs.namespace_name
  eventhub_name              = module.eventhubs.telemetry_hub_name
  eventhub_id                = module.eventhubs.telemetry_hub_id
  tags                       = local.tags
}

module "eventgrid" {
  source = "../../modules/eventgrid"
  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                = local.name_prefix
  location                   = var.primary_location
  resource_group_name        = azurerm_resource_group.main.name
  log_analytics_workspace_id = module.observability.workspace_id
  tags                       = local.tags
}

module "postgres" {
  source = "../../modules/postgres"
  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                           = local.name_prefix
  location                              = var.primary_location
  resource_group_name                   = azurerm_resource_group.main.name
  key_vault_id                          = module.keyvault.id
  key_vault_operator_role_assignment_id = module.keyvault.operator_secrets_officer_role_assignment_id
  tags                                  = local.tags
}

module "ml_stub" {
  source = "../../modules/ml-stub"
  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                = local.name_prefix
  location                   = var.primary_location
  resource_group_name        = azurerm_resource_group.main.name
  log_analytics_workspace_id = module.observability.workspace_id
  tags                       = local.tags
}

module "functions" {
  source = "../../modules/functions"
  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                        = local.name_prefix
  location                           = var.primary_location
  resource_group_name                = azurerm_resource_group.main.name
  log_analytics_workspace_id         = module.observability.workspace_id
  app_insights_connection_string     = module.observability.app_insights_connection_string
  storage_account_name               = module.storage.main_name
  storage_account_primary_access_key = module.storage.main_primary_access_key
  raw_archive_storage_account_id     = module.storage.raw_archive_id
  raw_archive_blob_endpoint          = module.storage.raw_archive_primary_blob_endpoint
  raw_archive_container_name         = module.storage.telemetry_raw_container_name
  eventhub_namespace_name            = module.eventhubs.namespace_name
  telemetry_hub_id                   = module.eventhubs.telemetry_hub_id
  telemetry_hub_name                 = module.eventhubs.telemetry_hub_name
  cosmos_account_id                  = module.cosmos.account_id
  cosmos_account_endpoint            = module.cosmos.account_endpoint
  cosmos_account_name                = module.cosmos.account_name
  cosmos_database_name               = module.cosmos.database_name
  cosmos_telemetry_container_name    = module.cosmos.telemetry_container_name
  tags                               = local.tags
}

module "crash_classifier" {
  source = "../../modules/crash-classifier"
  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                        = local.name_prefix
  location                           = var.primary_location
  resource_group_name                = azurerm_resource_group.main.name
  log_analytics_workspace_id         = module.observability.workspace_id
  app_insights_connection_string     = module.observability.app_insights_connection_string
  service_plan_id                    = module.functions.service_plan_id
  storage_account_name               = module.storage.main_name
  storage_account_primary_access_key = module.storage.main_primary_access_key
  eventhub_namespace_name            = module.eventhubs.namespace_name
  telemetry_hub_id                   = module.eventhubs.telemetry_hub_id
  cosmos_account_id                  = module.cosmos.account_id
  cosmos_account_endpoint            = module.cosmos.account_endpoint
  cosmos_account_name                = module.cosmos.account_name
  cosmos_database_name               = module.cosmos.database_name
  cosmos_telemetry_container_name    = module.cosmos.telemetry_container_name
  servicebus_namespace_name          = module.servicebus.namespace_name
  servicebus_queue_id                = module.servicebus.queue_id
  servicebus_queue_name              = module.servicebus.queue_name
  ml_stub_fqdn                       = module.ml_stub.ml_stub_fqdn
  tags                               = local.tags
}

module "metrics" {
  source = "../../modules/metrics"
  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                        = local.name_prefix
  location                           = var.primary_location
  resource_group_name                = azurerm_resource_group.main.name
  log_analytics_workspace_id         = module.observability.workspace_id
  app_insights_connection_string     = module.observability.app_insights_connection_string
  service_plan_id                    = module.functions.service_plan_id
  storage_account_name               = module.storage.main_name
  storage_account_primary_access_key = module.storage.main_primary_access_key
  eventhub_namespace_name            = module.eventhubs.namespace_name
  eventhub_name                      = module.eventhubs.telemetry_hub_name
  telemetry_hub_id                   = module.eventhubs.telemetry_hub_id
  tags                               = local.tags
}

module "notifier" {
  source = "../../modules/notifier"
  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                           = local.name_prefix
  location                              = var.primary_location
  resource_group_name                   = azurerm_resource_group.main.name
  log_analytics_workspace_id            = module.observability.workspace_id
  app_insights_connection_string        = module.observability.app_insights_connection_string
  service_plan_id                       = module.functions.service_plan_id
  storage_account_name                  = module.storage.main_name
  storage_account_primary_access_key    = module.storage.main_primary_access_key
  key_vault_id                          = module.keyvault.id
  key_vault_operator_role_assignment_id = module.keyvault.operator_secrets_officer_role_assignment_id
  servicebus_namespace_name             = module.servicebus.namespace_name
  servicebus_queue_id                   = module.servicebus.queue_id
  servicebus_queue_name                 = module.servicebus.queue_name
  cosmos_account_id                     = module.cosmos.account_id
  cosmos_account_endpoint               = module.cosmos.account_endpoint
  cosmos_account_name                   = module.cosmos.account_name
  cosmos_database_name                  = module.cosmos.database_name
  cosmos_notifications_container_name   = module.cosmos.notifications_container_name
  postgres_fqdn                         = module.postgres.fqdn
  postgres_database_name                = module.postgres.database_name
  postgres_notifier_password_secret_id  = module.postgres.notifier_password_secret_id
  tags                                  = local.tags
}
