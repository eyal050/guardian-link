module "aks" {
  source = "../../modules/aks"

  providers = {
    azurerm.workload = azurerm.workload
  }

  name                       = "aks-${local.name_prefix}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = var.primary_location
  dns_prefix                 = "${var.application_name}-${var.environment_name}"
  key_vault_id               = azurerm_key_vault.main.id
  acr_id                     = azurerm_container_registry.main.id
  log_analytics_workspace_id = module.observability.workspace_id
  tags                       = local.tags
}

# Event Hubs Data Receiver on the namespace: the consumer reads from
# the `telemetry` hub using the `inspector` consumer group.
resource "azurerm_role_assignment" "consumer_eh_receiver" {
  provider = azurerm.workload

  scope                = azurerm_eventhub_namespace.main.id
  role_definition_name = "Azure Event Hubs Data Receiver"
  principal_id         = module.aks.consumer_identity_principal_id
}

# Storage Blob Data Contributor on the operational storage account:
# the consumer writes checkpoint blobs to the `eh-checkpoints` container.
resource "azurerm_role_assignment" "consumer_storage_contributor" {
  provider = azurerm.workload

  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.aks.consumer_identity_principal_id
}
