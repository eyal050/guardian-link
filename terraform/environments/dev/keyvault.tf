# Key Vault for secrets that unavoidably require static credentials:
# ACS connection string, Postgres passwords.
# RBAC authorization model — consistent with the stack's identity posture.
#
# data.azurerm_client_config.current gives the object_id of whoever is
# running `terraform apply` so we can grant them Secrets Officer
# (write secrets during apply). This is the service principal or user
# authenticated via `az login`.

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "main" {
  provider = azurerm.workload

  name                = "kv-${local.name_prefix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  enable_rbac_authorization = true

  tags = local.tags
}

# Operator needs Secrets Officer to write the secrets below during apply.
resource "azurerm_role_assignment" "kv_operator_secrets_officer" {
  provider = azurerm.workload

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "appi_connection_string" {
  provider = azurerm.workload

  name         = "appi-connection-string"
  value        = azurerm_application_insights.main.connection_string
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.kv_operator_secrets_officer]
}
