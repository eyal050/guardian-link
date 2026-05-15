# Storage account for operational state. Holds the Event Hub consumer
# checkpoint container and the AzureWebJobsStorage content share for
# the telemetry-writer Function App. Raw-telemetry archive lives in a
# SEPARATE account (`raw_archive` below) so blast radius for archive
# ops is isolated from the host's WebJobs storage and so identity-only
# enforcement can diverge per account — see architecture decision #10.
#
# Standard_LRS in dev: cheapest single-region durability. min_tls_version
# matches the Event Hubs namespace. shared_access_key_enabled left at the
# provider default (true) because Linux Consumption Function Apps still
# need a connection-string-mode content share; the consumer + writer
# authenticate against the data plane via Entra ID regardless.

resource "random_string" "storage_suffix" {
  length  = 6
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_storage_account" "main" {
  provider = azurerm.workload

  name                = "stgl${var.environment_name}${random_string.storage_suffix.result}"
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = "Standard"
  account_replication_type = "LRS"

  public_network_access_enabled = true
  min_tls_version               = "TLS1_2"

  tags = var.tags
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

  name                       = "diag-st-blob-${var.name_prefix}"
  target_resource_id         = "${azurerm_storage_account.main.id}/blobServices/default"
  log_analytics_workspace_id = var.log_analytics_workspace_id

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


# -- Raw telemetry archive --
#
# Separate storage account for the telemetry-writer's NDJSON archive
# (slice β, architecture decision #10). Reasons not to fold this into
# the operational SA above:
# (a) blast-radius separation — destroy-recreate of the archive must
# not touch the host's AzureWebJobsStorage / EH checkpoints,
# (b) the operational SA needs shared keys for the Linux Consumption
# content share; the archive doesn't, so identity-only enforcement on
# the archive can be tightened independently in a later slice.
#
# shared_access_key_enabled is still true here (provider default) so
# `terraform apply` from a host without storage data-plane RBAC keeps
# working. Identity-only flip is a separate slice; the writer
# authenticates via MI (DefaultAzureCredential) either way and never
# uses the key.
resource "random_string" "raw_archive_suffix" {
  length  = 6
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_storage_account" "raw_archive" {
  provider = azurerm.workload

  name                = "stglraw${var.environment_name}${random_string.raw_archive_suffix.result}"
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = "Standard"
  account_replication_type = "LRS"

  public_network_access_enabled = true
  min_tls_version               = "TLS1_2"

  tags = var.tags
}

# `telemetry-raw` holds NDJSON-per-batch from the writer. Hive-style
# `events/year=YYYY/month=MM/.../p<part>-<startOff>-<endOff>.ndjson`
# paths are written by the function — Terraform doesn't pre-create the
# prefix structure (Blob namespaces are flat; prefixes are virtual).
resource "azurerm_storage_container" "telemetry_raw" {
  provider = azurerm.workload

  name               = "telemetry-raw"
  storage_account_id = azurerm_storage_account.raw_archive.id
}

# Diag setting on the archive's blob service so storage-side auth
# failures (writer MI not yet propagated, role missing) surface in LAW
# distinct from the operational SA's logs. Matches the operational SA
# diag pattern.
resource "azurerm_monitor_diagnostic_setting" "raw_archive_blob" {
  provider = azurerm.workload

  name                       = "diag-st-blob-${var.name_prefix}-raw"
  target_resource_id         = "${azurerm_storage_account.raw_archive.id}/blobServices/default"
  log_analytics_workspace_id = var.log_analytics_workspace_id

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
