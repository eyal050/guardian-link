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

variable "eventhub_namespace_name" {
  type        = string
  description = "EH namespace name — needed because the crash-classifier consumer group lives here on the EH telemetry hub."
}

variable "eventhub_name" {
  type        = string
  description = "EH name (telemetry) — same reason."
}

variable "tags" {
  type    = map(string)
  default = {}
}
