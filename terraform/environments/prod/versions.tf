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
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.0"
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
  subscription_id = var.workload_subscription_id
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# Grafana provider — reads GRAFANA_URL and GRAFANA_AUTH from environment.
# These are injected by run.sh (local) or the ADO bootstrap task (pipeline).
# During plan/validate stages, placeholder env vars keep provider init happy.
provider "grafana" {
  alias = "managed"
}
