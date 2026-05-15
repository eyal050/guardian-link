# PostgreSQL Flexible Server for the emergency contact registry.
# B_Standard_B1ms is the cheapest Flexible Server SKU — 1 vCore, 2 GiB RAM.
# Destroyed nightly so HA and geo-redundant backups are not needed.

# terraform_data shim: forwards the keyvault module's role-assignment id so
# the KV-secret resources below can depends_on it without a direct cross-
# module reference (modules cannot depends_on each other directly).
resource "terraform_data" "kv_role_dependency" {
  input = var.key_vault_operator_role_assignment_id
}

resource "random_password" "postgres_admin" {
  length           = 32
  special          = true
  override_special = "!#$%&*-_=+[]{}|:,.<>?"
}

resource "random_password" "postgres_notifier" {
  length           = 32
  special          = true
  override_special = "!#$%&*-_=+[]{}|:,.<>?"
}

resource "azurerm_key_vault_secret" "postgres_admin_password" {
  provider     = azurerm.workload
  name         = "postgres-admin-password"
  value        = random_password.postgres_admin.result
  key_vault_id = var.key_vault_id

  depends_on = [terraform_data.kv_role_dependency]
}

resource "azurerm_key_vault_secret" "postgres_notifier_password" {
  provider     = azurerm.workload
  name         = "postgres-notifier-password"
  value        = random_password.postgres_notifier.result
  key_vault_id = var.key_vault_id

  depends_on = [terraform_data.kv_role_dependency]
}

resource "azurerm_postgresql_flexible_server" "main" {
  provider = azurerm.workload

  name                = "psql-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name

  sku_name   = "B_Standard_B1ms"
  storage_mb = 32768
  version    = "16"

  administrator_login    = "psqladmin"
  administrator_password = random_password.postgres_admin.result

  authentication {
    active_directory_auth_enabled = false
    password_auth_enabled         = true
  }

  public_network_access_enabled = true

  # Azure assigns a zone automatically on Flexible Server creation; the
  # provider detects drift on subsequent plans. Ignore to keep plans clean.
  lifecycle {
    ignore_changes = [zone]
  }

  tags = var.tags
}

resource "azurerm_postgresql_flexible_server_database" "guardianlink" {
  provider  = azurerm.workload
  name      = "guardianlink"
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# 0.0.0.0-0.0.0.0 is the Azure magic range that allows connections from
# within Azure (including Function Apps). Required at runtime.
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  provider         = azurerm.workload
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Allow all IPs so the local machine can run the schema migration script.
# This server is destroyed nightly; the broad rule is intentional in dev.
resource "azurerm_postgresql_flexible_server_firewall_rule" "dev_all" {
  provider         = azurerm.workload
  name             = "AllowAllDev"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "255.255.255.255"
}
