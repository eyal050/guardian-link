variable "name_prefix" {
  type        = string
  description = "Shared name prefix for all resources."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to deploy into."
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "LAW ID for Function App diagnostic settings."
}

variable "app_insights_connection_string" {
  type        = string
  sensitive   = true
  description = "Application Insights connection string injected into the Function App."
}

variable "storage_account_name" {
  type        = string
  description = "Storage account name for AzureWebJobsStorage (Function host content share)."
}

variable "storage_account_primary_access_key" {
  type        = string
  sensitive   = true
  description = "Primary access key for the host storage account."
}

variable "raw_archive_storage_account_id" {
  type        = string
  description = "Raw-archive storage account ID — RBAC scope for Storage Blob Data Contributor on the writer MI."
}

variable "raw_archive_blob_endpoint" {
  type        = string
  description = "Raw-archive primary blob endpoint URL — used as BLOB_ARCHIVE_ACCOUNT app setting (full URL, not FQDN)."
}

variable "raw_archive_container_name" {
  type        = string
  description = "Raw-archive container name — BLOB_ARCHIVE_CONTAINER app setting."
}

variable "eventhub_namespace_name" {
  type        = string
  description = "Event Hub namespace name — used to build FQDN for identity-based EH trigger."
}

variable "telemetry_hub_id" {
  type        = string
  description = "Telemetry Event Hub ID — RBAC scope for the EH Data Receiver on the writer MI."
}

variable "telemetry_hub_name" {
  type        = string
  description = "Telemetry Event Hub name — used by the writer's consumer group."
}

variable "cosmos_account_id" {
  type        = string
  description = "Cosmos account ID — RBAC scope and role definition prefix for the Cosmos data-plane assignment."
}

variable "cosmos_account_endpoint" {
  type        = string
  description = "Cosmos account endpoint URL — COSMOS_ENDPOINT app setting."
}

variable "cosmos_account_name" {
  type        = string
  description = "Cosmos account name — required by azurerm_cosmosdb_sql_role_assignment."
}

variable "cosmos_database_name" {
  type        = string
  description = "Cosmos database name — COSMOS_DATABASE app setting."
}

variable "cosmos_telemetry_container_name" {
  type        = string
  description = "Cosmos telemetry container name — COSMOS_CONTAINER app setting."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all resources."
}
