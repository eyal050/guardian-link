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
