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
