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

terraform "$@"
