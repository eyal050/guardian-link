#!/usr/bin/env bash
# Wrapper around `terraform` for the prod environment.
#
# Prod's subscription was created via a one-time Stage 0 bootstrap (manually,
# with user `az` creds for Microsoft.Subscription/aliases/write) and is now
# referenced via TF_VAR_workload_subscription_id only. To bootstrap a fresh
# prod from scratch, temporarily add `resource "azurerm_subscription" "main"`
# to subscription.tf, apply with `-target`, capture the subscription_id, run
# `terraform state rm azurerm_subscription.main`, then restore the file.
set -euo pipefail

export ARM_SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:?Set ARM_SUBSCRIPTION_ID to your parent subscription ID}"

BACKEND_RESOURCE_GROUP="${TF_BACKEND_RESOURCE_GROUP:?Set TF_BACKEND_RESOURCE_GROUP}"
BACKEND_STORAGE_ACCOUNT="${TF_BACKEND_STORAGE_ACCOUNT:?Set TF_BACKEND_STORAGE_ACCOUNT}"
BACKEND_CONTAINER_NAME="${TF_BACKEND_CONTAINER:-tfstate}"
BACKEND_KEY="guardianlink-prod"

terraform init \
  -backend-config="resource_group_name=${BACKEND_RESOURCE_GROUP}" \
  -backend-config="storage_account_name=${BACKEND_STORAGE_ACCOUNT}" \
  -backend-config="container_name=${BACKEND_CONTAINER_NAME}" \
  -backend-config="key=${BACKEND_KEY}"

az account list --refresh >/dev/null

terraform "$@"
