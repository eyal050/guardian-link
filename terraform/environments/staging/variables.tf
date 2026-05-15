variable "workload_subscription_id" {
  type        = string
  description = "Staging workload subscription ID."
}

variable "billing_scope_id" {
  type        = string
  description = "MCA invoice-section scope for subscription creation."
}

variable "alert_email" {
  type        = string
  default     = ""
  description = "Email for Azure Monitor alert notifications."
}

variable "budget_contact_email" {
  type        = string
  default     = ""
  description = "Email for budget threshold alerts."
}

variable "owner" {
  type        = string
  default     = ""
  description = "Owner tag value."
}
