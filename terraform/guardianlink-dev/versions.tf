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
    # config injected at init via -backend-config; see run.sh
  }
}

# Default provider authenticates against the parent subscription
# (ARM_SUBSCRIPTION_ID from the environment) — used only to create the
# child subscription and its MG association.
provider "azurerm" {
  features {}
}

# Workload provider targets the newly-created child subscription.
# Every workload resource MUST set provider = azurerm.workload.
provider "azurerm" {
  alias           = "workload"
  subscription_id = azurerm_subscription.main.subscription_id
  features {}
}
