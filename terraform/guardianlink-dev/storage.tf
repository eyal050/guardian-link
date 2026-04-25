# Storage account for operational state. First container holds Event Hub
# consumer checkpoints; raw-telemetry archive + crash-payload containers
# (architecture.md) will land in this same account as separate slices.
# One account, many containers per docs/terraform-structure.md.
#
# Standard_LRS in dev: cheapest single-region durability. min_tls_version
# matches the Event Hubs namespace. shared_access_key_enabled left at the
# provider default (true) until the rest of the stack moves to identity-
# only enforcement; the consumer authenticates via Entra ID regardless.

resource "random_string" "storage_suffix" {
  length  = 6
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_storage_account" "main" {
  provider = azurerm.workload

  name                = "stgl${var.environment_name}${random_string.storage_suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.primary_location

  account_tier             = "Standard"
  account_replication_type = "LRS"

  public_network_access_enabled = true
  min_tls_version               = "TLS1_2"

  tags = local.tags
}

# Checkpoint store for the Event Hub consumer's BlobCheckpointStore.
# One blob per (consumer-group, partition) records the last processed
# offset; partition load-balancing across multiple consumer instances
# depends on this container existing and the consumer identity holding
# Storage Blob Data Contributor on it (granted in consumer/bootstrap.py).
resource "azurerm_storage_container" "eh_checkpoints" {
  provider = azurerm.workload

  name               = "eh-checkpoints"
  storage_account_id = azurerm_storage_account.main.id
}

# Blob-tier audit to Log Analytics. When checkpoints stop updating, the
# question is always "is the auth failing or is the app failing?" — these
# logs surface storage-side auth/permission failures distinct from any
# app-level error.
resource "azurerm_monitor_diagnostic_setting" "storage_blob" {
  provider = azurerm.workload

  name                       = "diag-st-blob-${local.name_prefix}"
  target_resource_id         = "${azurerm_storage_account.main.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "StorageRead"
  }

  enabled_log {
    category = "StorageWrite"
  }

  enabled_log {
    category = "StorageDelete"
  }

  metric {
    category = "Transaction"
    enabled  = true
  }
}
