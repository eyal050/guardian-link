variable "application_name" {
  type        = string
  description = "Workload name, used in resource names and tags."
}

variable "environment_name" {
  type        = string
  description = "Environment name (e.g. dev, prod)."
}

variable "primary_location" {
  type        = string
  description = "Azure region for all workload resources. Must have a mapping in locals.location_short_map."
}

variable "new_subscription_name" {
  type        = string
  description = "Display name for the new Azure subscription."
}

variable "budget_amount" {
  type        = number
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
  description = "Subscription ID of the existing workload subscription. Replaces azurerm_subscription.main for pipelines that lack billing alias permissions."
}
