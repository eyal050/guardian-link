resource "azurerm_kubernetes_cluster" "main" {
  provider = azurerm.workload

  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.dns_prefix

  private_cluster_enabled   = var.private_cluster
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                 = "system"
    vm_size              = var.vm_size
    auto_scaling_enabled = true
    min_count            = var.min_node_count
    max_count            = var.max_node_count
  }

  identity {
    type = "SystemAssigned"
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  network_profile {
    network_plugin    = "kubenet"
    network_policy    = "calico"
    load_balancer_sku = "standard"
  }

  oms_agent {
    log_analytics_workspace_id = var.log_analytics_workspace_id
  }

  tags = var.tags
}

resource "azurerm_user_assigned_identity" "consumer" {
  provider = azurerm.workload

  name                = "${var.name}-consumer-wi"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# Trust the cluster's OIDC issuer to exchange tokens for this managed identity.
resource "azurerm_federated_identity_credential" "consumer" {
  provider = azurerm.workload

  name                      = "${var.name}-consumer-fedcred"
  user_assigned_identity_id = azurerm_user_assigned_identity.consumer.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.consumer_k8s_namespace}:${var.consumer_k8s_service_account}"
}

# AKS kubelet identity needs AcrPull to pull images from ACR without admin creds.
resource "azurerm_role_assignment" "aks_acr_pull" {
  provider = azurerm.workload

  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

# CSI driver uses the consumer managed identity to fetch secrets from Key Vault.
resource "azurerm_role_assignment" "consumer_kv_secrets_user" {
  provider = azurerm.workload

  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.consumer.principal_id
}
