# Cosmos DB account: hot store for recent telemetry. Core SQL API per
# architecture.md decision #5; serverless capacity per decision #9.
#
# Why serverless (vs. provisioned autoscale): the dev workload is
# bursty and the stack is destroyed nightly. Provisioned autoscale
# bills against the *max* RU in a window with a 100-RU/s idle floor
# proportional to the configured ceiling — non-zero even when nothing
# is reading. Serverless bills per RU consumed with no floor. The
# 5000 RU/s per-container ceiling, lack of multi-region, and lack of
# continuous backup are accepted dev tradeoffs. Production would flip
# to provisioned autoscale once load is sustained — that switch
# requires recreating the account, so the decision is sticky.
#
# AAD-only auth (local_authentication_disabled = true) matches the
# rest of the stack (EH namespace, IoT Hub identity routing). Future
# telemetry-writer code path: Function MI gets 'Cosmos DB Built-in
# Data Contributor' scoped to this account when the Cosmos-write slice
# lands. Footgun: the Cosmos Data Explorer in the Azure Portal also
# needs a data-plane role assignment for the human user — keys won't
# work for portal browsing either.
#
# Single-region (West Europe) per decision #6. Session consistency:
# read-your-writes within a session, the default tradeoff. Strong /
# BoundedStaleness limit serverless behavior; Eventual gives up the
# read-after-write guarantee the classifier-after-writer path needs.

resource "azurerm_cosmosdb_account" "main" {
  provider = azurerm.workload

  name                = "cosmos-${local.name_prefix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name

  offer_type = "Standard"
  kind       = "GlobalDocumentDB"

  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.primary_location
    failover_priority = 0
  }

  public_network_access_enabled = true
  local_authentication_disabled = true

  tags = local.tags
}

# One database per workload — Cosmos billing/scoping is per-container
# in serverless, so further splitting buys nothing here.
resource "azurerm_cosmosdb_sql_database" "main" {
  provider = azurerm.workload

  name                = "guardianlink"
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
}

# Telemetry container. Partition key /device_id matches the existing
# producer schema (snake_case in the simulator's payload) — switching
# to camelCase /deviceId would force a write-time transformation in
# the telemetry-writer Function for no real benefit beyond convention.
#
# Read pattern that drives this choice (brainstorming-topics #2):
# "last N minutes of telemetry for device X" — single-partition
# lookup with a range filter on timestamp. crash_suspect lookups
# remain cross-partition; accepted at this scale. Migration trigger:
# if any single device exceeds ~10% of total writes, flip to a
# synthetic /device_id_yyyyMM key — that requires a container
# rebuild, so the migration is sticky.
#
# default_ttl 30 days = 2592000s. Hot-store retention per
# architecture.md "Storage layer". Raw archive in Blob (separate
# slice) handles longer retention. Setting a default_ttl on the
# container without overriding it per-document means every document
# expires after 30 days unless the writer sets a per-doc 'ttl' field.
resource "azurerm_cosmosdb_sql_container" "telemetry" {
  provider = azurerm.workload

  name                = "telemetry"
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.main.name

  partition_key_paths = ["/device_id"]
  partition_key_kind  = "Hash"

  default_ttl = 60 * 60 * 24 * 30
}

# Route Cosmos diagnostic data to LAW. DataPlaneRequests is the
# canonical "every read/write/query" log — first table to look at
# for "did our write actually land" or RU-spend spikiness.
# QueryRuntimeStatistics surfaces per-query RU + duration, useful
# for index tuning. ControlPlaneRequests covers RBAC + account
# config changes. Skipping Mongo/Cassandra/Gremlin/Table categories
# (SQL API only) and PartitionKeyRUConsumption (high cardinality,
# enable on demand when investigating hot-partition incidents).
resource "azurerm_monitor_diagnostic_setting" "cosmos" {
  provider = azurerm.workload

  name                       = "diag-cosmos-${local.name_prefix}"
  target_resource_id         = azurerm_cosmosdb_account.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "DataPlaneRequests"
  }

  enabled_log {
    category = "QueryRuntimeStatistics"
  }

  enabled_log {
    category = "ControlPlaneRequests"
  }

  metric {
    category = "Requests"
    enabled  = true
  }
}
