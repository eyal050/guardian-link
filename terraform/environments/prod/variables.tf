variable "application_name" {
  type        = string
  default     = "guardianlink"
  description = "Workload name, used in resource names and tags."
}

variable "environment_name" {
  type        = string
  default     = "prod"
  description = "Environment name (e.g. dev, prod)."
}

variable "primary_location" {
  type        = string
  default     = "westeurope"
  description = "Azure region for all workload resources. Must have a mapping in locals.location_short_map."
}

variable "new_subscription_name" {
  type        = string
  default     = "guardianlink-prod"
  description = "Display name for the new Azure subscription."
}

variable "budget_amount" {
  type        = number
  default     = 100
  description = "Monthly budget amount in the billing account currency."
}

variable "billing_scope_id" {
  type        = string
  description = "MCA invoice-section scope used to create the subscription. Format: /providers/Microsoft.Billing/billingAccounts/{id}/billingProfiles/{id}/invoiceSections/{id}"
}

variable "management_group_id" {
  type        = string
  default     = null
  description = "Optional management group resource ID to place the new subscription under. Null = not associated."
}

variable "budget_contact_email" {
  type        = string
  default     = ""
  description = "Email that receives budget threshold alerts."
}

variable "owner" {
  type        = string
  default     = ""
  description = "Used in the owner tag."
}

variable "workload_subscription_id" {
  type        = string
  default     = ""
  description = "Optional. If empty, run ./run.sh stage0 first to create the subscription, then set this to the printed ID and run ./run.sh apply. If set, the prod stack uses the provided subscription (skip Stage 0)."
}

variable "alert_email" {
  type        = string
  default     = ""
  description = "Email address for Azure Monitor alert notifications."
}

variable "grafana_viewer_principal_id" {
  type        = string
  default     = null
  description = "AAD object ID to assign Grafana Viewer role. Optional — omit for solo deployments."
}
