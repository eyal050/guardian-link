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

variable "partition_count" {
  type        = number
  default     = 4
  description = "Number of partitions on the telemetry Event Hub."
}

variable "message_retention_days" {
  type        = number
  default     = 1
  description = "Message retention in days."
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "Log Analytics workspace ID for diagnostic settings."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all resources."
}
