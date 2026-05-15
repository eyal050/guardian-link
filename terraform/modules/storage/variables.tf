variable "name_prefix" {
  type        = string
  description = "Shared name prefix."
}

variable "environment_name" {
  type        = string
  description = "Used in storage account names (must be globally unique, no dashes allowed)."
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
  description = "LAW ID for diagnostic settings on both storage accounts."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all resources."
}
