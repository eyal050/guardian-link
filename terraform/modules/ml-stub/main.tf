# ML stub Container App.
#
# Deploy order is two-step because the Container App image must exist in ACR
# before the app can start:
#
#   Step 1 — create ACR only:
#     terraform apply -target=azurerm_container_registry.main
#
#   Step 2 — build and push the image:
#     az acr build \
#       --registry acr$(terraform output -raw acr_name) \
#       --image ml-stub:latest \
#       ../../apps/ml-stub
#
#   Step 3 — apply everything:
#     terraform apply
#
# After the first full apply, re-deploying the image is:
#   az acr build ... && az containerapp update --image ...
# TF does not manage the image tag on subsequent deploys (see lifecycle block).

# ACR Basic — dev only. Admin credentials enable the Container App pull secret.
# In production: use managed identity pull (currently GA only on Dedicated plans).
resource "azurerm_container_registry" "main" {
  provider = azurerm.workload

  name                = "acr${replace(var.name_prefix, "-", "")}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = true

  tags = var.tags
}

# Container App Environment — Consumption workload profile (no dedicated infra).
resource "azurerm_container_app_environment" "main" {
  provider = azurerm.workload

  name                       = "cae-${var.name_prefix}"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  log_analytics_workspace_id = var.log_analytics_workspace_id

  tags = var.tags
}

# ML stub — always at least 1 replica so the classifier never cold-calls a
# scaled-to-zero container on the crash detection path.
resource "azurerm_container_app" "ml_stub" {
  provider = azurerm.workload

  name                         = "ca-${var.name_prefix}-ml-stub"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"

  registry {
    server               = azurerm_container_registry.main.login_server
    username             = azurerm_container_registry.main.admin_username
    password_secret_name = "acr-admin-password"
  }

  secret {
    name  = "acr-admin-password"
    value = azurerm_container_registry.main.admin_password
  }

  template {
    min_replicas = 1
    max_replicas = 3

    container {
      name   = "ml-stub"
      image  = "${azurerm_container_registry.main.login_server}/ml-stub:latest"
      cpu    = 0.25
      memory = "0.5Gi"
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8080

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  # Don't let TF revert the image after the first deploy. Image updates go
  # through `az acr build` + `az containerapp update`, not terraform apply.
  lifecycle {
    ignore_changes = [
      template[0].container[0].image,
    ]
  }

  tags = var.tags
}
