variable "name_prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }

variable "app_insights_id" {
  type        = string
  description = "App Insights ID -- scope for the no_telemetry and crash_spike alerts."
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "LAW ID -- scope for the no_iot_connections alert."
}

variable "alert_email" {
  type        = string
  description = "Email address for the action group."
}

variable "tags" {
  type    = map(string)
  default = {}
}
