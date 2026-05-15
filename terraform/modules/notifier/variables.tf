variable "name_prefix" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "app_insights_connection_string" {
  type      = string
  sensitive = true
}

variable "service_plan_id" {
  type = string
}

variable "storage_account_name" {
  type = string
}

variable "storage_account_primary_access_key" {
  type      = string
  sensitive = true
}

variable "key_vault_id" {
  type = string
}

variable "key_vault_operator_role_assignment_id" {
  type        = string
  description = "Used via terraform_data shim for explicit ordering on the ACS connection-string secret write."
}

variable "servicebus_namespace_name" {
  type = string
}

variable "servicebus_queue_id" {
  type = string
}

variable "servicebus_queue_name" {
  type = string
}

variable "cosmos_account_id" {
  type = string
}

variable "cosmos_account_endpoint" {
  type = string
}

variable "cosmos_account_name" {
  type = string
}

variable "cosmos_database_name" {
  type = string
}

variable "cosmos_notifications_container_name" {
  type = string
}

variable "postgres_fqdn" {
  type = string
}

variable "postgres_database_name" {
  type = string
}

variable "postgres_notifier_password_secret_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
