terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.69.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "azurerm" {
    # config injected at init via -backend-config
    # key = "guardianlink-staging"
  }
}

provider "azurerm" {
  features {}
}

provider "azurerm" {
  alias           = "workload"
  subscription_id = var.workload_subscription_id
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
