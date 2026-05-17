variable "name_prefix" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "key_vault_id" {
  type = string
}

variable "key_vault_operator_role_assignment_id" {
  type        = string
  description = "Pass module.keyvault.operator_secrets_officer_role_assignment_id; module uses it via a terraform_data shim for explicit ordering."
}

variable "tags" {
  type    = map(string)
  default = {}
}
