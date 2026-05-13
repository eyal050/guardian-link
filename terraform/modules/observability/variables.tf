variable "name_prefix" {
  type        = string
  description = "Shared name prefix for all resources, e.g. guardianlink-dev-weu."
}

variable "location" {
  type        = string
  description = "Azure region for all resources."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to deploy into."
}

variable "log_retention_days" {
  type        = number
  default     = 30
  description = "Log Analytics retention period in days."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all resources."
}
