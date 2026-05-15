variable "name_prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "app_insights_connection_string" {
  type        = string
  sensitive   = true
  description = "Stored as the appi-connection-string KV secret for downstream consumers (CSI driver, etc.)."
}
variable "tags" {
  type    = map(string)
  default = {}
}
