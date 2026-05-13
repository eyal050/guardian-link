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

variable "storage_account_name" {
  type        = string
  description = "Storage account name for AzureWebJobsStorage (Function host content share)."
}

variable "storage_account_primary_connection_string" {
  type        = string
  sensitive   = true
  description = "Primary connection string for the host storage account."
}

variable "app_insights_connection_string" {
  type        = string
  sensitive   = true
  description = "Application Insights connection string injected into all Function Apps."
}

variable "eventhub_namespace_name" {
  type        = string
  description = "Event Hub namespace name — used to build FQDN for identity-based trigger."
}

variable "servicebus_namespace_name" {
  type        = string
  description = "Service Bus namespace name — used to build FQDN for identity-based trigger."
}

variable "cosmos_account_name" {
  type        = string
  description = "Cosmos DB account name — used to build endpoint URI."
}

variable "key_vault_uri" {
  type        = string
  description = "Key Vault URI for Key Vault reference app settings."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all Function Apps."
}
