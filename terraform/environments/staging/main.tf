# GuardianLink — staging environment
#
# This environment is a stub. It is not currently deployed.
# It demonstrates the module consumption pattern that would be used
# when promoting from dev to staging.
#
# Promotion checklist (before first staging deploy):
#   1. Provision a dedicated Azure subscription for staging
#   2. Create a guardianlink-staging ADO variable group (mirror of guardianlink-backend)
#   3. Set workload_subscription_id in staging.tfvars
#   4. Run: terraform init -backend-config="key=guardianlink-staging" ...
#   5. terraform plan && terraform apply

locals {
  environment_name = "staging"
  location         = "westeurope"
  location_short   = "weu"
  name_prefix      = "guardianlink-${local.environment_name}-${local.location_short}"

  tags = {
    workload    = "guardianlink"
    environment = local.environment_name
    managed_by  = "terraform"
    owner       = var.owner
  }
}

resource "azurerm_resource_group" "main" {
  provider = azurerm.workload

  name     = "rg-guardianlink-${local.environment_name}"
  location = local.location
  tags     = local.tags
}

# ── Observability ─────────────────────────────────────────────────────────────

module "observability" {
  source = "../../modules/observability"

  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix         = local.name_prefix
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name
  log_retention_days  = 30
  tags                = local.tags
}

# ── Event streaming ───────────────────────────────────────────────────────────

module "eventhub" {
  source = "../../modules/eventhub"

  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                = local.name_prefix
  location                   = local.location
  resource_group_name        = azurerm_resource_group.main.name
  partition_count            = 4
  message_retention_days     = 1
  log_analytics_workspace_id = module.observability.workspace_id
  tags                       = local.tags
}

# ── IoT Hub ───────────────────────────────────────────────────────────────────

module "iot" {
  source = "../../modules/iot"

  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                = local.name_prefix
  location                   = local.location
  resource_group_name        = azurerm_resource_group.main.name
  eventhub_id                = module.eventhub.telemetry_hub_id
  eventhub_namespace_name    = module.eventhub.namespace_name
  eventhub_name              = module.eventhub.telemetry_hub_name
  log_analytics_workspace_id = module.observability.workspace_id
  tags                       = local.tags
}

# ── Service Bus ───────────────────────────────────────────────────────────────

module "servicebus" {
  source = "../../modules/servicebus"

  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                = local.name_prefix
  location                   = local.location
  resource_group_name        = azurerm_resource_group.main.name
  lock_duration              = "PT5M"
  max_delivery_count         = 5
  message_ttl                = "P14D"
  log_analytics_workspace_id = module.observability.workspace_id
  tags                       = local.tags
}

# ── Function Apps ─────────────────────────────────────────────────────────────
# Uncomment when modules/functions module extraction is complete.
#
# module "functions" {
#   source = "../../modules/functions"
#
#   providers = {
#     azurerm.workload = azurerm.workload
#   }
#
#   name_prefix                              = local.name_prefix
#   location                                 = local.location
#   resource_group_name                      = azurerm_resource_group.main.name
#   app_insights_connection_string           = module.observability.app_insights_connection_string
#   eventhub_namespace_name                  = module.eventhub.namespace_name
#   servicebus_namespace_name                = module.servicebus.namespace_name
#   tags                                     = local.tags
# }
