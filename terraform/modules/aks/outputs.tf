output "cluster_name" {
  value       = azurerm_kubernetes_cluster.main.name
  description = "AKS cluster name."
}

output "cluster_id" {
  value       = azurerm_kubernetes_cluster.main.id
  description = "AKS cluster resource ID."
}

output "oidc_issuer_url" {
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
  description = "OIDC issuer URL for federated identity credentials."
}

output "consumer_identity_client_id" {
  value       = azurerm_user_assigned_identity.consumer.client_id
  description = "Client ID annotated on the consumer Kubernetes service account."
}

output "consumer_identity_principal_id" {
  value       = azurerm_user_assigned_identity.consumer.principal_id
  description = "Principal ID used for RBAC assignments outside the module."
}

output "producer_identity_client_id" {
  value       = azurerm_user_assigned_identity.producer.client_id
  description = "Client ID annotated on the producer Kubernetes service account."
}

output "producer_identity_principal_id" {
  value       = azurerm_user_assigned_identity.producer.principal_id
  description = "Principal ID used for the IoT Hub Registry Contributor assignment."
}

output "kube_config_raw" {
  value       = azurerm_kubernetes_cluster.main.kube_config_raw
  sensitive   = true
  description = "Raw kubeconfig (sensitive). Use az aks get-credentials in pipelines instead."
}
