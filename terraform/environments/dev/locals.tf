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

  tags = {
    workload    = var.application_name
    environment = var.environment_name
    managed_by  = "terraform"
    cost_center = "interview-prep"
    owner       = var.owner
  }
}
