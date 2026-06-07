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

    # Azure populates upgrade_settings on cluster creation even when not
    # specified, then a refresh-only plan flags it as drift. Pinning the
    # provider's defaults here keeps plans clean.
    upgrade_settings {
      drain_timeout_in_minutes      = 0
      max_surge                     = "10%"
      node_soak_duration_in_minutes = 0
    }
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

# --- Producer (device simulator) workload identity ---------------------------
# The producer pod self-registers its device roster in IoT Hub at startup using
# this identity (control-plane), then connects as each device with the returned
# SAS key. No manual bootstrap, no .env files. The IoT Hub Registry Contributor
# grant lives in the environment (it needs the IoT Hub scope).
resource "azurerm_user_assigned_identity" "producer" {
  provider = azurerm.workload

  name                = "${var.name}-producer-wi"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "producer" {
  provider = azurerm.workload

  name                      = "${var.name}-producer-fedcred"
  user_assigned_identity_id = azurerm_user_assigned_identity.producer.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.producer_k8s_namespace}:${var.producer_k8s_service_account}"
}

# CSI driver uses the producer identity to fetch the App Insights secret.
resource "azurerm_role_assignment" "producer_kv_secrets_user" {
  provider = azurerm.workload

  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.producer.principal_id
}
