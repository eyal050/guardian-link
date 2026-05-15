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
