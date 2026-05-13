locals {
  location_short_map = {
    westeurope  = "weu"
    northeurope = "neu"
    eastus      = "eus"
    eastus2     = "eus2"
    westus      = "wus"
    westus2     = "wus2"
  }

  location_short = local.location_short_map[var.primary_location]
  name_prefix    = "${var.application_name}-${var.environment_name}-${local.location_short}"

  # Resolved subscription ID for the workload provider.
  # Prefer the variable (set after Stage 0). Falls back to the in-state resource
  # so Stage 0's targeted apply doesn't require the variable to be set yet.
  workload_subscription_id = (
    var.workload_subscription_id != ""
    ? var.workload_subscription_id
    : azurerm_subscription.main.subscription_id
  )

  tags = {
    workload    = var.application_name
    environment = var.environment_name
    managed_by  = "terraform"
    cost_center = "interview-prep"
    owner       = var.owner
  }
}
