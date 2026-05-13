#!/usr/bin/env bash
# Wrapper around `terraform` for the prod environment.
#
# Three modes:
#   ./run.sh stage0    — create the prod subscription (run once, with `az login` credentials)
#                        Prints the subscription ID; set it as TF_VAR_workload_subscription_id
#                        or in terraform.tfvars before running ./run.sh apply.
#   ./run.sh apply     — Stage 1 (Grafana) + Stage 2 (everything)
#   ./run.sh <command> — passthrough (plan, destroy, output, state, ...)
set -euo pipefail

# Parent subscription the default azurerm provider authenticates against
# (used by Stage 0 to create the child subscription).
export ARM_SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:?Set ARM_SUBSCRIPTION_ID to your parent subscription ID}"

# State backend — pre-existing, outside this repo's Terraform.
BACKEND_RESOURCE_GROUP="${TF_BACKEND_RESOURCE_GROUP:?Set TF_BACKEND_RESOURCE_GROUP}"
BACKEND_STORAGE_ACCOUNT="${TF_BACKEND_STORAGE_ACCOUNT:?Set TF_BACKEND_STORAGE_ACCOUNT}"
BACKEND_CONTAINER_NAME="${TF_BACKEND_CONTAINER:-tfstate}"
# State key is fixed at guardianlink-prod. Do not change without manual state migration.
BACKEND_KEY="guardianlink-prod"

terraform init \
  -backend-config="resource_group_name=${BACKEND_RESOURCE_GROUP}" \
  -backend-config="storage_account_name=${BACKEND_STORAGE_ACCOUNT}" \
  -backend-config="container_name=${BACKEND_CONTAINER_NAME}" \
  -backend-config="key=${BACKEND_KEY}"

# Refresh Azure CLI cached subscription list so the workload provider can
# authenticate against the child subscription after Stage 0 creates it.
az account list --refresh >/dev/null

COMMAND="${1:-}"

case "$COMMAND" in
  stage0)
    # Stage 0: create the prod subscription. Requires the caller's `az login`
    # credentials to have Microsoft.Subscription/aliases/write on the billing
    # scope. Other workload resources are not in scope for this apply.
    shift
    terraform apply -target=azurerm_subscription.main "$@"

    SUB_ID=$(terraform output -raw subscription_id 2>/dev/null || \
             terraform state show azurerm_subscription.main | \
             awk '/^[[:space:]]+subscription_id[[:space:]]+=/ {gsub(/"/,""); print $3; exit}')

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Stage 0 complete. Prod subscription_id: ${SUB_ID}"
    echo ""
    echo "Next step: set this in terraform.tfvars or export it, then run:"
    echo "    export TF_VAR_workload_subscription_id=${SUB_ID}"
    echo "    ./run.sh apply"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ;;

  apply)
    shift  # forward extra args to both applies

    # Stage 1: create Azure Managed Grafana + role assignments so Stage 2
    # has the endpoint URL and an Azure AD bearer token to talk to it.
    terraform apply \
      -target=azurerm_dashboard_grafana.main \
      -target=azurerm_role_assignment.grafana_admin \
      -target=azurerm_role_assignment.grafana_viewer \
      -target=azurerm_role_assignment.grafana_mon_reader \
      "$@"

    echo "Waiting 30s for role assignment propagation..."
    sleep 30

    export GRAFANA_URL
    GRAFANA_URL=$(terraform output -raw grafana_endpoint)
    export GRAFANA_AUTH
    GRAFANA_AUTH=$(az account get-access-token \
      --resource ce34e7e5-485f-4d76-964f-b3d2b16d1e4f \
      --query accessToken -o tsv)

    # Stage 2: full apply.
    terraform apply "$@"
    ;;

  *)
    terraform "$@"
    ;;
esac
