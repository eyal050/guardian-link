terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source                = "hashicorp/azurerm"
      configuration_aliases = [azurerm.workload]
    }
    random = {
      source = "hashicorp/random"
    }
  }
}
