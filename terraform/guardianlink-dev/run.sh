#!/usr/bin/env bash
# Wrapper around `terraform` that injects the external state-backend config
# and the parent subscription ID. Usage: ./run.sh plan | ./run.sh apply | etc.
set -euo pipefail

# Parent subscription the default azurerm provider authenticates against
# (to create the child subscription). Child-sub resources use the aliased
# provider and do not read this.
export ARM_SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:?Set ARM_SUBSCRIPTION_ID to your parent subscription ID}"

# State backend — pre-existing, outside this repo's Terraform.
# Export TF_BACKEND_RESOURCE_GROUP, TF_BACKEND_STORAGE_ACCOUNT before running.
BACKEND_RESOURCE_GROUP="${TF_BACKEND_RESOURCE_GROUP:?Set TF_BACKEND_RESOURCE_GROUP}"
BACKEND_STORAGE_ACCOUNT="${TF_BACKEND_STORAGE_ACCOUNT:?Set TF_BACKEND_STORAGE_ACCOUNT}"
BACKEND_CONTAINER_NAME="${TF_BACKEND_CONTAINER:-tfstate}"
# State key matches the stack directory name so renaming one forces renaming
# the other — prevents silent divergence between code and state location.
BACKEND_KEY="guardianlink-dev"

terraform init \
  -backend-config="resource_group_name=${BACKEND_RESOURCE_GROUP}" \
  -backend-config="storage_account_name=${BACKEND_STORAGE_ACCOUNT}" \
  -backend-config="container_name=${BACKEND_CONTAINER_NAME}" \
  -backend-config="key=${BACKEND_KEY}"

# Refresh Azure CLI's cached subscription list so the aliased
# azurerm.workload provider can authenticate against the child sub.
# Without this, the first apply that creates the subscription leaves
# the CLI cache stale and the next TF step errors with
# "subscription ID ... is not known by Azure CLI".
az account list --refresh >/dev/null

COMMAND="${1:-}"

if [ "$COMMAND" = "apply" ]; then
  shift  # remaining args (e.g. -auto-approve) forwarded to both applies

  # Stage 1: create Grafana Azure resource and Admin role assignment so we can
  # obtain the endpoint URL and a valid API token for Stage 2.
  terraform apply \
    -target=azurerm_dashboard_grafana.main \
    -target=azurerm_role_assignment.grafana_admin \
    "$@"

  # Azure role-assignment propagation takes a few seconds.
  echo "Waiting 30s for role assignment propagation..."
  sleep 30

  # Obtain the Grafana endpoint and an Azure AD bearer token.
  # Azure Managed Grafana accepts AAD tokens at its HTTP API — no Grafana
  # service account key needed. Token TTL is 1 hour, ample for any apply.
  export GRAFANA_URL
  GRAFANA_URL=$(terraform output -raw grafana_endpoint)
  export GRAFANA_AUTH
  GRAFANA_AUTH=$(az account get-access-token \
    --resource ce34e7e5-485f-4d76-964f-b3d2b16d1e4f \
    --query accessToken -o tsv)

  # Stage 2: full apply — Grafana provider now has URL + auth via env vars.
  terraform apply "$@"

else
  terraform "$@"
fi
