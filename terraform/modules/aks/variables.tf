variable "name" {
  type        = string
  description = "AKS cluster name."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to deploy into."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "dns_prefix" {
  type        = string
  description = "DNS prefix for the cluster FQDN."
}

variable "vm_size" {
  type        = string
  default     = "Standard_B2s"
  description = "VM size for the system node pool."
}

variable "min_node_count" {
  type        = number
  default     = 1
  description = "Minimum node count for autoscaling."
}

variable "max_node_count" {
  type        = number
  default     = 3
  description = "Maximum node count for autoscaling."
}

variable "key_vault_id" {
  type        = string
  description = "Key Vault resource ID. Consumer managed identity receives Key Vault Secrets User."
}

variable "acr_id" {
  type        = string
  description = "Container Registry resource ID. AKS kubelet identity receives AcrPull."
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "Log Analytics Workspace resource ID for the OMS agent."
}

variable "consumer_k8s_namespace" {
  type        = string
  default     = "consumer"
  description = "Kubernetes namespace where the consumer service account lives."
}

variable "consumer_k8s_service_account" {
  type        = string
  default     = "consumer-sa"
  description = "Kubernetes service account name for Workload Identity binding."
}

variable "private_cluster" {
  type        = bool
  default     = false
  description = "Enable private API server. Set true in prod; requires VPN/bastion for ADO pipeline access."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all resources."
}
