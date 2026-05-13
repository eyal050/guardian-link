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

variable "eventhub_id" {
  type        = string
  description = "Resource ID of the telemetry Event Hub. IoT Hub's system identity gets Data Sender on this scope."
}

variable "eventhub_namespace_name" {
  type        = string
  description = "Event Hub namespace hostname (used to build the endpoint URI)."
}

variable "eventhub_name" {
  type        = string
  description = "Event Hub name (entity path for the routing endpoint)."
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
