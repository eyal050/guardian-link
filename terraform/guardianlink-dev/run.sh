#!/usr/bin/env bash
# Wrapper around `terraform` that injects the external state-backend config
# and the parent subscription ID. Usage: ./run.sh plan | ./run.sh apply | etc.
set -euo pipefail

# Parent subscription the default azurerm provider authenticates against
# (to create the child subscription). Child-sub resources use the aliased
# provider and do not read this.
export ARM_SUBSCRIPTION_ID="c770b313-1ad0-4dce-864b-f083acbfba68"

# State backend — pre-existing, outside this repo's Terraform.
BACKEND_RESOURCE_GROUP="rg-terraform-state-dev"
BACKEND_STORAGE_ACCOUNT="eyaltfstorage22042026"
BACKEND_CONTAINER_NAME="tfstate"
# State key matches the stack directory name so renaming one forces renaming
# the other — prevents silent divergence between code and state location.
BACKEND_KEY="guardianlink-dev"

terraform init \
  -backend-config="resource_group_name=${BACKEND_RESOURCE_GROUP}" \
  -backend-config="storage_account_name=${BACKEND_STORAGE_ACCOUNT}" \
  -backend-config="container_name=${BACKEND_CONTAINER_NAME}" \
  -backend-config="key=${BACKEND_KEY}"

terraform "$@"
