variable "name_prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "log_analytics_workspace_id" { type = string }
variable "app_insights_connection_string" {
  type      = string
  sensitive = true
}
variable "service_plan_id" { type = string }
variable "storage_account_name" { type = string }
variable "storage_account_primary_access_key" {
  type      = string
  sensitive = true
}
variable "eventhub_namespace_name" { type = string }
variable "eventhub_name" {
  type        = string
  description = "Telemetry hub name (consumer group attaches here)."
}
variable "telemetry_hub_id" {
  type        = string
  description = "Telemetry hub ID (receiver role scope)."
}
variable "tags" {
  type    = map(string)
  default = {}
}
