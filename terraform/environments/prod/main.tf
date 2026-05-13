# GuardianLink — production environment
#
# This environment is a stub. It is not currently deployed.
# Production differs from staging in:
#   - Dedicated subscription with stricter RBAC and budget alerts
#   - Provisioned (not serverless) Cosmos DB throughput
#   - Private endpoints on all data stores
#   - Higher Event Hub partition count and longer retention
#   - Longer log retention (90 days minimum for compliance)
#   - Alerting wired to a PagerDuty/Opsgenie action group, not just email
#
# Promotion from staging requires:
#   1. Manual sign-off on a terraform plan output reviewed by a second engineer
#   2. Deployment during a maintenance window
#   3. Post-deploy smoke test against the prod IoT Hub endpoint

locals {
  environment_name = "prod"
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

module "observability" {
  source = "../../modules/observability"

  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix         = local.name_prefix
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name
  log_retention_days  = 90
  tags                = local.tags
}

module "eventhub" {
  source = "../../modules/eventhub"

  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix                = local.name_prefix
  location                   = local.location
  resource_group_name        = azurerm_resource_group.main.name
  partition_count            = 8
  message_retention_days     = 7
  log_analytics_workspace_id = module.observability.workspace_id
  tags                       = local.tags
}

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
