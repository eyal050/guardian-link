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

variable "lock_duration" {
  type        = string
  default     = "PT5M"
  description = "ISO 8601 lock duration for the crash-confirmed queue."
}

variable "max_delivery_count" {
  type        = number
  default     = 5
  description = "Max delivery attempts before a message is dead-lettered."
}

variable "message_ttl" {
  type        = string
  default     = "P14D"
  description = "ISO 8601 message TTL."
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
