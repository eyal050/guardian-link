# Function Apps: telemetry-writer, crash-classifier, notifier, metrics.
# Separate apps per workload — different SLOs, independent scale and blast radius.
# See docs/architecture.md — decision on separate Function Apps per workload.
#
# This module is a skeleton showing the interface contract.
# The full resource definitions live in environments/dev/ while the module
# API is being finalised; terraform state mv is required to migrate existing
# resources once module extraction is complete.

resource "azurerm_service_plan" "functions" {
  provider = azurerm.workload

  name                = "asp-${var.name_prefix}-fn"
  location            = var.location
  resource_group_name = var.resource_group_name
  os_type             = "Linux"
  sku_name            = "Y1"

  tags = var.tags
}

# telemetry_writer, crash_classifier, notifier, metrics Function Apps
# are defined in the full module — see environments/dev/functions.tf
# for the complete resource definitions used as the module source.
