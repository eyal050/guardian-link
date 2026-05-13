# Terraform Prod Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a production Terraform environment that mirrors dev's flat stack, deployed to a new `guardianlink-prod` Azure subscription created by Terraform itself, and reusable via a parametrised ADO pipeline template that drives both dev and prod.

**Architecture:** `terraform/environments/prod/` is a flat copy of `terraform/environments/dev/` with prod-specific tfvars and a `subscription.tf` that keeps `azurerm_subscription.main` in state (vs dev's `removed` block). A three-stage `run.sh` handles the subscription-creation chicken-and-egg: Stage 0 creates the subscription with user CLI credentials, Stage 1 deploys Grafana, Stage 2 deploys everything. A new `pipelines/templates/terraform-env.yml` template wraps validate/plan/apply logic; `infra.yml` calls it twice (dev → prod with manual approval gate).

**Tech Stack:** Terraform 1.9.8, azurerm 4.69, Azure subscription creation, ADO YAML pipeline templates, ADO environment approval gates.

**Repo:** `/home/eyal/repos/guardian-link/` (separate from the pipeline-forge monorepo this plan was authored in)

---

## File Structure

### Created files
- `terraform/environments/prod/versions.tf` — provider versions + provider blocks (copy of dev)
- `terraform/environments/prod/variables.tf` — vars with prod defaults
- `terraform/environments/prod/locals.tf` — prefix, tags, subscription-id resolution
- `terraform/environments/prod/subscription.tf` — `azurerm_subscription.main` (kept, not removed)
- `terraform/environments/prod/rg.tf` — resource groups
- `terraform/environments/prod/observability.tf` — Log Analytics + App Insights
- `terraform/environments/prod/eventhubs.tf` — Event Hub namespace + telemetry hub
- `terraform/environments/prod/iot.tf` — IoT Hub
- `terraform/environments/prod/servicebus.tf` — Service Bus + queues
- `terraform/environments/prod/cosmos.tf` — Cosmos DB
- `terraform/environments/prod/storage.tf` — storage accounts
- `terraform/environments/prod/keyvault.tf` — Key Vault
- `terraform/environments/prod/postgres.tf` — Postgres Flexible
- `terraform/environments/prod/functions.tf` — Function App plans + apps
- `terraform/environments/prod/crash-classifier.tf` — classifier function
- `terraform/environments/prod/notifier.tf` — notifier function
- `terraform/environments/prod/metrics.tf` — metrics function
- `terraform/environments/prod/eventgrid.tf` — Event Grid subscriptions
- `terraform/environments/prod/grafana.tf` — Azure Managed Grafana
- `terraform/environments/prod/grafana-dashboards.tf` — Grafana dashboards (via grafana provider)
- `terraform/environments/prod/dashboards.tf` — Azure portal dashboards
- `terraform/environments/prod/alerts.tf` — Monitor alerts + action group
- `terraform/environments/prod/budget.tf` — subscription budget
- `terraform/environments/prod/ml-stub.tf` — Container App ML stub
- `terraform/environments/prod/outputs.tf` — outputs
- `terraform/environments/prod/run.sh` — three-stage wrapper
- `terraform/environments/prod/terraform.tfvars.example` — sample tfvars for prod
- `pipelines/templates/terraform-env.yml` — reusable ADO template

### Modified files
- `pipelines/infra.yml` — refactored to call template for dev + prod
- `docs/terraform-structure.md` — document prod env + template pattern

### Deleted files
- `terraform/environments/prod/main.tf` — old module-consuming stub (superseded by flat layout)

---

## Task 1: Wipe prod stub and scaffold prod base files

**Files:**
- Delete: `terraform/environments/prod/main.tf`
- Delete: `terraform/environments/prod/variables.tf` (will be recreated from dev)
- Delete: `terraform/environments/prod/versions.tf` (will be recreated from dev)
- Create: `terraform/environments/prod/versions.tf` (copy of dev)
- Create: `terraform/environments/prod/locals.tf` (copy of dev with cost_center kept)

- [ ] **Step 1: Delete the old prod stub files**

```bash
cd /home/eyal/repos/guardian-link
git rm terraform/environments/prod/main.tf
git rm terraform/environments/prod/variables.tf
git rm terraform/environments/prod/versions.tf
```

- [ ] **Step 2: Copy versions.tf, locals.tf from dev to prod**

```bash
cp terraform/environments/dev/versions.tf terraform/environments/prod/versions.tf
cp terraform/environments/dev/locals.tf   terraform/environments/prod/locals.tf
git add terraform/environments/prod/versions.tf terraform/environments/prod/locals.tf
```

- [ ] **Step 3: Verify versions.tf and locals.tf are byte-identical to dev**

Run: `diff terraform/environments/dev/versions.tf terraform/environments/prod/versions.tf && diff terraform/environments/dev/locals.tf terraform/environments/prod/locals.tf`
Expected: no output (files identical)

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(terraform/prod): scaffold prod env, drop module stub"
```

---

## Task 2: Create prod variables.tf with prod defaults

**Files:**
- Create: `terraform/environments/prod/variables.tf`

- [ ] **Step 1: Write `terraform/environments/prod/variables.tf`**

```hcl
variable "application_name" {
  type        = string
  default     = "guardianlink"
  description = "Workload name, used in resource names and tags."
}

variable "environment_name" {
  type        = string
  default     = "prod"
  description = "Environment name (e.g. dev, prod)."
}

variable "primary_location" {
  type        = string
  default     = "westeurope"
  description = "Azure region for all workload resources. Must have a mapping in locals.location_short_map."
}

variable "new_subscription_name" {
  type        = string
  default     = "guardianlink-prod"
  description = "Display name for the new Azure subscription."
}

variable "budget_amount" {
  type        = number
  default     = 100
  description = "Monthly budget amount in the billing account currency."
}

variable "billing_scope_id" {
  type        = string
  description = "MCA invoice-section scope used to create the subscription. Format: /providers/Microsoft.Billing/billingAccounts/{id}/billingProfiles/{id}/invoiceSections/{id}"
}

variable "management_group_id" {
  type        = string
  default     = null
  description = "Optional management group resource ID to place the new subscription under. Null = not associated."
}

variable "budget_contact_email" {
  type        = string
  default     = ""
  description = "Email that receives budget threshold alerts."
}

variable "owner" {
  type        = string
  default     = ""
  description = "Used in the owner tag."
}

variable "workload_subscription_id" {
  type        = string
  default     = ""
  description = "Optional. If empty, run ./run.sh stage0 first to create the subscription, then set this to the printed ID and run ./run.sh apply. If set, the prod stack uses the provided subscription (skip Stage 0)."
}

variable "alert_email" {
  type        = string
  default     = ""
  description = "Email address for Azure Monitor alert notifications."
}

variable "grafana_viewer_principal_id" {
  type        = string
  default     = null
  description = "AAD object ID to assign Grafana Viewer role. Optional — omit for solo deployments."
}
```

- [ ] **Step 2: Verify it parses with terraform fmt**

Run: `cd terraform/environments/prod && terraform fmt -check variables.tf`
Expected: exit 0, no output

- [ ] **Step 3: Commit**

```bash
git add terraform/environments/prod/variables.tf
git commit -m "feat(terraform/prod): add variables with prod defaults"
```

---

## Task 3: Copy all dev resource .tf files to prod

**Files:**
- Create: prod versions of all resource files

- [ ] **Step 1: Copy each resource file from dev to prod (excluding subscription.tf, run.sh, tfvars)**

```bash
cd /home/eyal/repos/guardian-link
for f in rg.tf observability.tf eventhubs.tf iot.tf servicebus.tf cosmos.tf \
         storage.tf keyvault.tf postgres.tf functions.tf crash-classifier.tf \
         notifier.tf metrics.tf eventgrid.tf grafana.tf grafana-dashboards.tf \
         dashboards.tf alerts.tf budget.tf ml-stub.tf outputs.tf; do
  cp "terraform/environments/dev/$f" "terraform/environments/prod/$f"
done
git add terraform/environments/prod/*.tf
```

- [ ] **Step 2: Verify all files copied**

Run: `ls terraform/environments/prod/*.tf | wc -l`
Expected: 24 (versions, variables, locals + 21 copied)

- [ ] **Step 3: Sanity diff — confirm files identical to dev for now**

Run: `diff -r terraform/environments/dev terraform/environments/prod | grep "^Only in" || echo "all files in sync"`
Expected: shows only files unique to each side (dev has subscription.tf + run.sh + tfvars + tfvars.example; prod has none yet)

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(terraform/prod): copy dev resource definitions"
```

---

## Task 4: Create prod subscription.tf (live, not removed)

**Files:**
- Create: `terraform/environments/prod/subscription.tf`

Unlike dev (where `azurerm_subscription.main` was removed from state because the ADO SP lacks billing alias permissions), prod keeps the resource. Stage 0 of `run.sh` applies it with the user's CLI credentials, after which the subscription is owned by Terraform.

- [ ] **Step 1: Write `terraform/environments/prod/subscription.tf`**

```hcl
# Prod manages its own subscription. First-time deploy:
#   1. Run ./run.sh stage0 with your own `az login` credentials
#      (the ADO SP lacks Microsoft.Subscription/aliases/write).
#   2. Capture the printed subscription_id and set TF_VAR_workload_subscription_id
#      (or workload_subscription_id in tfvars) for subsequent runs.
# After Stage 0, the subscription is in state and azurerm.workload uses it
# directly when var.workload_subscription_id is empty.
resource "azurerm_subscription" "main" {
  subscription_name = var.new_subscription_name
  billing_scope_id  = var.billing_scope_id
  tags              = local.tags
}

resource "azurerm_management_group_subscription_association" "main" {
  count = var.management_group_id == null ? 0 : 1

  management_group_id = var.management_group_id
  subscription_id     = "/subscriptions/${azurerm_subscription.main.subscription_id}"
}
```

- [ ] **Step 2: Update locals.tf to resolve subscription_id from var or resource**

Edit `terraform/environments/prod/locals.tf`, replace the entire `locals { ... }` block with:

```hcl
locals {
  location_short_map = {
    westeurope  = "weu"
    northeurope = "neu"
    eastus      = "eus"
    eastus2     = "eus2"
    westus      = "wus"
    westus2     = "wus2"
  }

  location_short = local.location_short_map[var.primary_location]
  name_prefix    = "${var.application_name}-${var.environment_name}-${local.location_short}"

  # Resolved subscription ID for the workload provider.
  # Prefer the variable (set after Stage 0). Falls back to the in-state resource
  # so Stage 0's targeted apply doesn't require the variable to be set yet.
  workload_subscription_id = (
    var.workload_subscription_id != ""
    ? var.workload_subscription_id
    : azurerm_subscription.main.subscription_id
  )

  tags = {
    workload    = var.application_name
    environment = var.environment_name
    managed_by  = "terraform"
    cost_center = "interview-prep"
    owner       = var.owner
  }
}
```

- [ ] **Step 3: Update versions.tf to use local.workload_subscription_id**

Edit `terraform/environments/prod/versions.tf`, find the workload provider block and replace:

```hcl
provider "azurerm" {
  alias           = "workload"
  subscription_id = var.workload_subscription_id
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
```

with:

```hcl
provider "azurerm" {
  alias           = "workload"
  subscription_id = local.workload_subscription_id
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
```

- [ ] **Step 4: Verify terraform fmt**

Run: `cd terraform/environments/prod && terraform fmt -check`
Expected: exit 0

- [ ] **Step 5: Commit**

```bash
git add terraform/environments/prod/subscription.tf terraform/environments/prod/locals.tf terraform/environments/prod/versions.tf
git commit -m "feat(terraform/prod): keep azurerm_subscription.main in state"
```

---

## Task 5: Create prod terraform.tfvars.example

**Files:**
- Create: `terraform/environments/prod/terraform.tfvars.example`

- [ ] **Step 1: Write `terraform/environments/prod/terraform.tfvars.example`**

```hcl
application_name      = "guardianlink"
environment_name      = "prod"
primary_location      = "westeurope"
new_subscription_name = "guardianlink-prod"
budget_amount         = 200
billing_scope_id      = "/providers/Microsoft.Billing/billingAccounts/<account-id>/billingProfiles/<profile-id>/invoiceSections/<section-id>"

# Optional:
# management_group_id  = "/providers/Microsoft.Management/managementGroups/<mg-name>"
# budget_contact_email = "you@example.com"
# owner                = "you@example.com"

# First-time deploy: leave workload_subscription_id commented out.
# Run ./run.sh stage0 to create the subscription, then set this and run ./run.sh apply.
# workload_subscription_id = "<output of: terraform output -raw subscription_id>"

# Optional: AAD object ID for Grafana Viewer.
# grafana_viewer_principal_id = "<aad-object-id>"
```

- [ ] **Step 2: Commit**

```bash
git add terraform/environments/prod/terraform.tfvars.example
git commit -m "feat(terraform/prod): add tfvars example"
```

---

## Task 6: Create prod run.sh with Stage 0 + Stages 1-2

**Files:**
- Create: `terraform/environments/prod/run.sh`

- [ ] **Step 1: Write `terraform/environments/prod/run.sh`**

```bash
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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x terraform/environments/prod/run.sh
```

- [ ] **Step 3: Verify shellcheck-clean**

Run: `shellcheck terraform/environments/prod/run.sh`
Expected: exit 0 (or only style warnings, no errors)

If `shellcheck` is not installed, skip this step.

- [ ] **Step 4: Add subscription_id output to outputs.tf**

Check if `outputs.tf` already exposes the subscription ID:

Run: `grep -n "subscription_id" terraform/environments/prod/outputs.tf`

If absent, append to `terraform/environments/prod/outputs.tf`:

```hcl
output "subscription_id" {
  value       = azurerm_subscription.main.subscription_id
  description = "ID of the prod subscription created by Stage 0."
}
```

If `outputs.tf` (copied from dev) already references `var.workload_subscription_id` somewhere, leave those outputs alone — the new one is in addition.

- [ ] **Step 5: Commit**

```bash
git add terraform/environments/prod/run.sh terraform/environments/prod/outputs.tf
git commit -m "feat(terraform/prod): add three-stage run.sh wrapper"
```

---

## Task 7: Validate prod stack locally

**Files:** (no code changes — verification step)

- [ ] **Step 1: Run terraform fmt + validate**

```bash
cd /home/eyal/repos/guardian-link/terraform/environments/prod
terraform fmt -check -recursive
TF_BACKEND_RESOURCE_GROUP=placeholder \
TF_BACKEND_STORAGE_ACCOUNT=placeholder \
ARM_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000 \
GRAFANA_URL=https://placeholder.invalid \
GRAFANA_AUTH=placeholder \
  terraform init -backend=false -input=false
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 2: If validate fails on missing variables, set placeholders and retry**

If validate complains about required vars (e.g. `billing_scope_id`), set them via env:

```bash
TF_VAR_billing_scope_id="/providers/Microsoft.Billing/billingAccounts/aaa/billingProfiles/bbb/invoiceSections/ccc" \
TF_VAR_alert_email=test@example.com \
TF_VAR_budget_contact_email=test@example.com \
TF_VAR_owner=test \
  terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Cleanup local .terraform**

```bash
rm -rf terraform/environments/prod/.terraform terraform/environments/prod/.terraform.lock.hcl
```

- [ ] **Step 4: No commit needed — verification step only**

---

## Task 8: Create pipelines/templates/terraform-env.yml

**Files:**
- Create: `pipelines/templates/terraform-env.yml`

This template captures the full validate → plan → apply flow for a single Terraform environment. Both dev and prod will call it.

- [ ] **Step 1: Write `pipelines/templates/terraform-env.yml`**

```yaml
# pipelines/templates/terraform-env.yml
# Reusable Terraform stage template, called once per environment by infra.yml.
#
# Three stages produced: validate (env-scoped), plan, apply (two-stage Grafana).
# Approval gates and variable groups are injected via parameters.
parameters:
  - name: environment
    type: string
  - name: tfDir
    type: string
  - name: variableGroup
    type: string
  - name: adoEnvironment
    type: string
  - name: stateKey
    type: string
  - name: dependsOn
    type: object
    default: []

stages:
  - stage: validate_${{ parameters.environment }}
    displayName: Validate (${{ parameters.environment }})
    dependsOn: ${{ parameters.dependsOn }}
    variables:
      - group: guardianlink-backend
      - group: ${{ parameters.variableGroup }}
    jobs:
      - job: validate
        displayName: fmt-check + validate
        pool:
          vmImage: ubuntu-latest
        steps:
          - template: steps/install-terraform.yml

          - task: AzureCLI@2
            displayName: Terraform init (no backend) + validate
            inputs:
              azureSubscription: guardianlink-azure
              scriptType: bash
              scriptLocation: inlineScript
              addSpnToEnvironment: true
              inlineScript: |
                set -euo pipefail
                cd ${{ parameters.tfDir }}
                export ARM_CLIENT_ID=$servicePrincipalId
                export ARM_TENANT_ID=$tenantId
                export ARM_SUBSCRIPTION_ID=$(TF_BACKEND_SUBSCRIPTION_ID)
                export ARM_USE_OIDC=true
                export ARM_OIDC_TOKEN=$idToken
                terraform init -backend=false -input=false
                terraform fmt -check -recursive
                terraform validate
            env:
              GRAFANA_URL: "https://placeholder.grafana.invalid"
              GRAFANA_AUTH: "placeholder"

  - stage: plan_${{ parameters.environment }}
    displayName: Plan ${{ parameters.environment }} (review)
    dependsOn: validate_${{ parameters.environment }}
    condition: succeeded()
    variables:
      - group: guardianlink-backend
      - group: ${{ parameters.variableGroup }}
      - group: guardianlink-infra-outputs
    jobs:
      - job: plan
        displayName: terraform plan
        pool:
          vmImage: ubuntu-latest
        steps:
          - template: steps/install-terraform.yml

          - task: AzureCLI@2
            displayName: Terraform init + plan
            inputs:
              azureSubscription: guardianlink-azure
              scriptType: bash
              scriptLocation: inlineScript
              addSpnToEnvironment: true
              inlineScript: |
                set -euo pipefail
                cd ${{ parameters.tfDir }}
                export ARM_CLIENT_ID=$servicePrincipalId
                export ARM_TENANT_ID=$tenantId
                export ARM_SUBSCRIPTION_ID=$(TF_BACKEND_SUBSCRIPTION_ID)
                export ARM_USE_OIDC=true
                export ARM_OIDC_TOKEN=$idToken
                terraform init \
                  -backend-config="subscription_id=$(TF_BACKEND_SUBSCRIPTION_ID)" \
                  -backend-config="resource_group_name=$(TF_BACKEND_RESOURCE_GROUP)" \
                  -backend-config="storage_account_name=$(TF_BACKEND_STORAGE_ACCOUNT)" \
                  -backend-config="container_name=$(TF_BACKEND_CONTAINER)" \
                  -backend-config="key=${{ parameters.stateKey }}" \
                  -input=false
                GRAFANA_URL="${GRAFANA_ENDPOINT:-https://placeholder.grafana.invalid}"
                export GRAFANA_URL
                export GRAFANA_AUTH
                GRAFANA_AUTH=$(az account get-access-token \
                  --resource ce34e7e5-485f-4d76-964f-b3d2b16d1e4f \
                  --query accessToken -o tsv 2>/dev/null || echo "placeholder")
                terraform plan -input=false
            env:
              TF_VAR_billing_scope_id: $(TF_VAR_billing_scope_id)
              TF_VAR_alert_email: $(TF_VAR_alert_email)
              TF_VAR_budget_contact_email: $(TF_VAR_budget_contact_email)
              TF_VAR_owner: $(TF_VAR_owner)
              TF_VAR_workload_subscription_id: $(TF_VAR_workload_subscription_id)
              GRAFANA_ENDPOINT: $(GRAFANA_ENDPOINT)

  - stage: apply_${{ parameters.environment }}
    displayName: Apply ${{ parameters.environment }}
    dependsOn: plan_${{ parameters.environment }}
    condition: succeeded()
    variables:
      - group: guardianlink-backend
      - group: ${{ parameters.variableGroup }}
      - group: guardianlink-infra-outputs
    jobs:
      - deployment: apply
        displayName: terraform apply (two-stage Grafana)
        environment: ${{ parameters.adoEnvironment }}
        pool:
          vmImage: ubuntu-latest
        strategy:
          runOnce:
            deploy:
              steps:
                - checkout: self

                - template: steps/install-terraform.yml

                - task: AzureCLI@2
                  displayName: "Stage 1 — Grafana + role assignments + ACR"
                  inputs:
                    azureSubscription: guardianlink-azure
                    scriptType: bash
                    scriptLocation: inlineScript
                    addSpnToEnvironment: true
                    inlineScript: |
                      set -euo pipefail
                      cd ${{ parameters.tfDir }}
                      export ARM_CLIENT_ID=$servicePrincipalId
                      export ARM_TENANT_ID=$tenantId
                      export ARM_SUBSCRIPTION_ID=$(TF_BACKEND_SUBSCRIPTION_ID)
                      export ARM_USE_OIDC=true
                      export ARM_OIDC_TOKEN=$idToken
                      terraform init \
                        -backend-config="subscription_id=$(TF_BACKEND_SUBSCRIPTION_ID)" \
                        -backend-config="resource_group_name=$(TF_BACKEND_RESOURCE_GROUP)" \
                        -backend-config="storage_account_name=$(TF_BACKEND_STORAGE_ACCOUNT)" \
                        -backend-config="container_name=$(TF_BACKEND_CONTAINER)" \
                        -backend-config="key=${{ parameters.stateKey }}" \
                        -input=false
                      terraform apply -auto-approve -input=false \
                        -target=azurerm_dashboard_grafana.main \
                        -target=azurerm_role_assignment.grafana_admin \
                        -target=azurerm_role_assignment.grafana_viewer \
                        -target=azurerm_role_assignment.grafana_mon_reader \
                        -target=azurerm_container_registry.main
                  env:
                    TF_VAR_billing_scope_id: $(TF_VAR_billing_scope_id)
                    TF_VAR_alert_email: $(TF_VAR_alert_email)
                    TF_VAR_budget_contact_email: $(TF_VAR_budget_contact_email)
                    TF_VAR_owner: $(TF_VAR_owner)
                    TF_VAR_workload_subscription_id: $(TF_VAR_workload_subscription_id)
                    GRAFANA_URL: "https://placeholder.grafana.invalid"
                    GRAFANA_AUTH: "placeholder"

                - task: AzureCLI@2
                  displayName: "Build ml-stub image + import orphaned resources"
                  inputs:
                    azureSubscription: guardianlink-azure
                    scriptType: bash
                    scriptLocation: inlineScript
                    addSpnToEnvironment: true
                    inlineScript: |
                      set -euo pipefail
                      cd ${{ parameters.tfDir }}
                      export ARM_CLIENT_ID=$servicePrincipalId
                      export ARM_TENANT_ID=$tenantId
                      export ARM_SUBSCRIPTION_ID=$(TF_BACKEND_SUBSCRIPTION_ID)
                      export ARM_USE_OIDC=true
                      export ARM_OIDC_TOKEN=$idToken
                      terraform init \
                        -backend-config="subscription_id=$(TF_BACKEND_SUBSCRIPTION_ID)" \
                        -backend-config="resource_group_name=$(TF_BACKEND_RESOURCE_GROUP)" \
                        -backend-config="storage_account_name=$(TF_BACKEND_STORAGE_ACCOUNT)" \
                        -backend-config="container_name=$(TF_BACKEND_CONTAINER)" \
                        -backend-config="key=${{ parameters.stateKey }}" \
                        -input=false -reconfigure

                      ACR_NAME=$(terraform output -raw acr_name)
                      if ! az acr repository show --name "$ACR_NAME" --image "ml-stub:latest" &>/dev/null; then
                        echo "Building ml-stub image..."
                        az acr build --registry "$ACR_NAME" --image ml-stub:latest ../../../apps/ml-stub/
                      else
                        echo "ml-stub:latest already in ACR, skipping build."
                      fi

                      export GRAFANA_URL
                      GRAFANA_URL=$(terraform output -raw grafana_endpoint)
                      export GRAFANA_AUTH
                      GRAFANA_AUTH=$(az account get-access-token \
                        --resource ce34e7e5-485f-4d76-964f-b3d2b16d1e4f \
                        --query accessToken -o tsv)
                      terraform init \
                        -backend-config="subscription_id=$(TF_BACKEND_SUBSCRIPTION_ID)" \
                        -backend-config="resource_group_name=$(TF_BACKEND_RESOURCE_GROUP)" \
                        -backend-config="storage_account_name=$(TF_BACKEND_STORAGE_ACCOUNT)" \
                        -backend-config="container_name=$(TF_BACKEND_CONTAINER)" \
                        -backend-config="key=${{ parameters.stateKey }}" \
                        -input=false -reconfigure

                      if ! terraform state show grafana_data_source.azure_monitor > /dev/null 2>&1; then
                        echo "Importing grafana_data_source.azure_monitor..."
                        terraform import grafana_data_source.azure_monitor azure-monitor-oob
                      else
                        echo "grafana_data_source.azure_monitor already in state."
                      fi

                      CA_ID="/subscriptions/$(TF_VAR_workload_subscription_id)/resourceGroups/rg-guardianlink-${{ parameters.environment }}/providers/Microsoft.App/containerApps/ca-guardianlink-${{ parameters.environment }}-weu-ml-stub"
                      if ! terraform state show azurerm_container_app.ml_stub > /dev/null 2>&1; then
                        if az containerapp show --ids "$CA_ID" &>/dev/null; then
                          echo "Importing azurerm_container_app.ml_stub..."
                          terraform import azurerm_container_app.ml_stub "$CA_ID"
                        fi
                      else
                        echo "azurerm_container_app.ml_stub already in state."
                      fi
                  env:
                    TF_VAR_billing_scope_id: $(TF_VAR_billing_scope_id)
                    TF_VAR_alert_email: $(TF_VAR_alert_email)
                    TF_VAR_budget_contact_email: $(TF_VAR_budget_contact_email)
                    TF_VAR_owner: $(TF_VAR_owner)
                    TF_VAR_workload_subscription_id: $(TF_VAR_workload_subscription_id)

                - task: AzureCLI@2
                  displayName: "Stage 2 — full apply"
                  inputs:
                    azureSubscription: guardianlink-azure
                    scriptType: bash
                    scriptLocation: inlineScript
                    addSpnToEnvironment: true
                    inlineScript: |
                      set -euo pipefail
                      cd ${{ parameters.tfDir }}
                      export ARM_CLIENT_ID=$servicePrincipalId
                      export ARM_TENANT_ID=$tenantId
                      export ARM_SUBSCRIPTION_ID=$(TF_BACKEND_SUBSCRIPTION_ID)
                      export ARM_USE_OIDC=true
                      export ARM_OIDC_TOKEN=$idToken
                      terraform init \
                        -backend-config="subscription_id=$(TF_BACKEND_SUBSCRIPTION_ID)" \
                        -backend-config="resource_group_name=$(TF_BACKEND_RESOURCE_GROUP)" \
                        -backend-config="storage_account_name=$(TF_BACKEND_STORAGE_ACCOUNT)" \
                        -backend-config="container_name=$(TF_BACKEND_CONTAINER)" \
                        -backend-config="key=${{ parameters.stateKey }}" \
                        -input=false -reconfigure
                      echo "Waiting 30s for role assignment propagation..."
                      sleep 30
                      export GRAFANA_URL
                      GRAFANA_URL=$(terraform output -raw grafana_endpoint)
                      export GRAFANA_AUTH
                      GRAFANA_AUTH=$(az account get-access-token \
                        --resource ce34e7e5-485f-4d76-964f-b3d2b16d1e4f \
                        --query accessToken -o tsv)
                      terraform apply -auto-approve -input=false
                  env:
                    TF_VAR_billing_scope_id: $(TF_VAR_billing_scope_id)
                    TF_VAR_alert_email: $(TF_VAR_alert_email)
                    TF_VAR_budget_contact_email: $(TF_VAR_budget_contact_email)
                    TF_VAR_owner: $(TF_VAR_owner)
                    TF_VAR_workload_subscription_id: $(TF_VAR_workload_subscription_id)
```

- [ ] **Step 2: Create the Install Terraform step template**

Create `pipelines/templates/steps/install-terraform.yml`:

```yaml
# pipelines/templates/steps/install-terraform.yml
# Installs the pinned Terraform version into /usr/local/bin.
steps:
  - bash: |
      set -euo pipefail
      INSTALL_DIR="${AGENT_TEMPDIRECTORY}/terraform-install"
      rm -rf "$INSTALL_DIR"
      mkdir -p "$INSTALL_DIR"

      curl -fsSL \
        "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
        -o "$INSTALL_DIR/terraform.zip"

      unzip -o "$INSTALL_DIR/terraform.zip" -d "$INSTALL_DIR"
      sudo install -m 0755 "$INSTALL_DIR/terraform" /usr/local/bin/terraform

      terraform version
    displayName: Install Terraform
    env:
      TERRAFORM_VERSION: $(TERRAFORM_VERSION)
```

- [ ] **Step 3: Commit**

```bash
git add pipelines/templates/terraform-env.yml pipelines/templates/steps/install-terraform.yml
git commit -m "feat(pipelines): add reusable terraform-env template"
```

---

## Task 9: Refactor pipelines/infra.yml to call template for dev

**Files:**
- Modify: `pipelines/infra.yml`

The current `infra.yml` is ~580 lines of inline stages. After this task it becomes a thin orchestrator. The "Update guardianlink-infra-outputs variable group" and "Trigger app pipelines" stages are dev-specific post-deploy concerns that stay outside the template.

- [ ] **Step 1: Stash the existing infra.yml and write the new one**

```bash
cp pipelines/infra.yml /tmp/infra.yml.bak
```

Replace `pipelines/infra.yml` with this new content:

```yaml
# pipelines/infra.yml
name: '$(Build.BuildId) - $(Date:yyyyMMdd) - $(Rev:r)'

parameters:
  - name: action
    displayName: 'Action'
    type: string
    default: apply
    values:
      - apply
      - destroy

trigger:
  branches:
    include:
      - main
  paths:
    include:
      - terraform/environments/dev/**
      - terraform/environments/prod/**
      - pipelines/infra.yml
      - pipelines/templates/**

variables:
  - name: TERRAFORM_VERSION
    value: 1.9.8

stages:
  - ${{ if eq(parameters.action, 'apply') }}:
    - template: templates/terraform-env.yml
      parameters:
        environment: dev
        tfDir: terraform/environments/dev
        variableGroup: guardianlink-dev
        adoEnvironment: dev
        stateKey: guardianlink-dev

    - stage: post_apply_dev
      displayName: Post-apply Dev
      dependsOn: apply_dev
      condition: succeeded()
      variables:
        - group: guardianlink-backend
        - group: guardianlink-dev
        - group: guardianlink-infra-outputs
      jobs:
        - job: publish_and_trigger
          displayName: Publish outputs + trigger app pipelines
          pool:
            vmImage: ubuntu-latest
          steps:
            - template: templates/steps/install-terraform.yml

            - task: AzureCLI@2
              displayName: Update guardianlink-infra-outputs variable group
              env:
                ADO_SETUP_PAT: $(ADO_SETUP_PAT)
                ADO_ORG: $(ADO_ORG)
                ADO_PROJECT_ID: $(ADO_PROJECT_ID)
              inputs:
                azureSubscription: guardianlink-azure
                scriptType: bash
                scriptLocation: inlineScript
                addSpnToEnvironment: true
                inlineScript: |
                  set -euo pipefail
                  cd terraform/environments/dev
                  export ARM_CLIENT_ID=$servicePrincipalId
                  export ARM_TENANT_ID=$tenantId
                  export ARM_SUBSCRIPTION_ID=$(TF_BACKEND_SUBSCRIPTION_ID)
                  export ARM_USE_OIDC=true
                  export ARM_OIDC_TOKEN=$idToken
                  terraform init \
                    -backend-config="subscription_id=$(TF_BACKEND_SUBSCRIPTION_ID)" \
                    -backend-config="resource_group_name=$(TF_BACKEND_RESOURCE_GROUP)" \
                    -backend-config="storage_account_name=$(TF_BACKEND_STORAGE_ACCOUNT)" \
                    -backend-config="container_name=$(TF_BACKEND_CONTAINER)" \
                    -backend-config="key=guardianlink-dev" \
                    -input=false -reconfigure
                  TF_JSON=$(terraform output -json)
                  RG=$(echo "$TF_JSON"             | jq -r '.resource_group_name.value')
                  APPI=$(echo "$TF_JSON"           | jq -r '.app_insights_name.value')
                  ACR_SERVER=$(echo "$TF_JSON"     | jq -r '.acr_login_server.value')
                  ACR_NAME=$(echo "$TF_JSON"       | jq -r '.acr_name.value')
                  FUNC_TW=$(echo "$TF_JSON"        | jq -r '.func_telemetry_writer_name.value')
                  FUNC_CC=$(echo "$TF_JSON"        | jq -r '.func_crash_classifier_name.value')
                  FUNC_NOT=$(echo "$TF_JSON"       | jq -r '.func_notifier_name.value')
                  FUNC_MET=$(echo "$TF_JSON"       | jq -r '.func_metrics_name.value')
                  CA_ML=$(echo "$TF_JSON"          | jq -r '.container_app_ml_stub_name.value')
                  GRAFANA_ENDPOINT=$(echo "$TF_JSON"   | jq -r '.grafana_endpoint.value')

                  ADO_PROJECT="guardianlink"
                  VG_NAME="guardianlink-infra-outputs"
                  API="https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_apis/distributedtask"

                  VARIABLES=$(jq -n \
                    --arg rg "$RG" --arg appi "$APPI" \
                    --arg acr_s "$ACR_SERVER" --arg acr_n "$ACR_NAME" \
                    --arg tw "$FUNC_TW" --arg cc "$FUNC_CC" \
                    --arg not "$FUNC_NOT" --arg met "$FUNC_MET" \
                    --arg ca "$CA_ML" \
                    --arg grafana_ep "$GRAFANA_ENDPOINT" \
                    '{
                      RESOURCE_GROUP_NAME:        {value: $rg},
                      APP_INSIGHTS_NAME:          {value: $appi},
                      ACR_LOGIN_SERVER:           {value: $acr_s},
                      ACR_NAME:                   {value: $acr_n},
                      FUNC_TELEMETRY_WRITER_NAME: {value: $tw},
                      FUNC_CRASH_CLASSIFIER_NAME: {value: $cc},
                      FUNC_NOTIFIER_NAME:         {value: $not},
                      FUNC_METRICS_NAME:          {value: $met},
                      CONTAINER_APP_ML_STUB_NAME: {value: $ca},
                      GRAFANA_ENDPOINT:           {value: $grafana_ep}
                    }')

                  PROJECT_REF=$(jq -n \
                    --arg vgname "$VG_NAME" \
                    --arg proj_id "$ADO_PROJECT_ID" \
                    --arg proj_name "$ADO_PROJECT" \
                    '[{name: $vgname, projectReference: {id: $proj_id, name: $proj_name}}]')

                  VG_RESP=$(curl -sf -u ":${ADO_SETUP_PAT}" \
                    "${API}/variablegroups?groupName=${VG_NAME}&api-version=7.0")
                  VG_ID=$(echo "$VG_RESP" | jq -r '.value[0].id // empty')

                  if [ -n "$VG_ID" ]; then
                    PAYLOAD=$(jq -n \
                      --argjson id "$VG_ID" --arg name "$VG_NAME" \
                      --argjson vars "$VARIABLES" \
                      --argjson refs "$PROJECT_REF" \
                      '{id: $id, name: $name, type: "Vsts", variables: $vars, variableGroupProjectReferences: $refs}')
                    curl -sf -u ":${ADO_SETUP_PAT}" \
                      -X PUT -H "Content-Type: application/json" \
                      -d "$PAYLOAD" \
                      "${API}/variablegroups/${VG_ID}?api-version=7.0" > /dev/null
                    echo "Variable group ${VG_NAME} updated (id=${VG_ID})."
                  else
                    PAYLOAD=$(jq -n \
                      --arg name "$VG_NAME" \
                      --argjson vars "$VARIABLES" \
                      --argjson refs "$PROJECT_REF" \
                      '{name: $name, type: "Vsts", variables: $vars, variableGroupProjectReferences: $refs}')
                    curl -sf -u ":${ADO_SETUP_PAT}" \
                      -X POST -H "Content-Type: application/json" \
                      -d "$PAYLOAD" \
                      "${API}/variablegroups?api-version=7.0" > /dev/null
                    echo "Variable group ${VG_NAME} created."
                  fi

            - bash: |
                set -euo pipefail
                API="https://dev.azure.com/${ADO_ORG}/guardianlink/_apis/pipelines"
                PAYLOAD='{"resources":{"repositories":{"self":{"refName":"refs/heads/main"}}}}'
                # Pipeline IDs: 7=telemetry-writer, 8=crash-classifier,
                #               9=notifier, 10=metrics, 11=ml-stub
                for pid in 7 8 9 10 11; do
                  BODY=$(curl -s -u ":${ADO_SETUP_PAT}" \
                    -X POST -H "Content-Type: application/json" \
                    -d "$PAYLOAD" \
                    -w "\nHTTP_STATUS:%{http_code}" \
                    "${API}/${pid}/runs?api-version=7.0")
                  STATUS=$(echo "$BODY" | grep "HTTP_STATUS:" | cut -d: -f2)
                  echo "Pipeline ${pid}: HTTP ${STATUS}"
                  if [ "$STATUS" != "200" ] && [ "$STATUS" != "201" ]; then
                    echo "--- Response body ---"
                    echo "$BODY" | grep -v "HTTP_STATUS:"
                    echo "---------------------"
                    exit 1
                  fi
                done
              displayName: Trigger app pipelines
              env:
                ADO_SETUP_PAT: $(ADO_SETUP_PAT)
                ADO_ORG: $(ADO_ORG)

  - ${{ if eq(parameters.action, 'destroy') }}:
    - stage: destroy_dev
      displayName: Destroy Dev
      dependsOn: []
      variables:
        - group: guardianlink-backend
        - group: guardianlink-dev
        - group: guardianlink-infra-outputs
      jobs:
        - deployment: destroy
          displayName: terraform destroy
          environment: dev
          pool:
            vmImage: ubuntu-latest
          strategy:
            runOnce:
              deploy:
                steps:
                  - checkout: self

                  - template: templates/steps/install-terraform.yml

                  - task: AzureCLI@2
                    displayName: terraform destroy
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      addSpnToEnvironment: true
                      inlineScript: |
                        set -euo pipefail
                        cd terraform/environments/dev
                        export ARM_CLIENT_ID=$servicePrincipalId
                        export ARM_TENANT_ID=$tenantId
                        export ARM_SUBSCRIPTION_ID=$(TF_BACKEND_SUBSCRIPTION_ID)
                        export ARM_USE_OIDC=true
                        export ARM_OIDC_TOKEN=$idToken
                        terraform init \
                          -backend-config="subscription_id=$(TF_BACKEND_SUBSCRIPTION_ID)" \
                          -backend-config="resource_group_name=$(TF_BACKEND_RESOURCE_GROUP)" \
                          -backend-config="storage_account_name=$(TF_BACKEND_STORAGE_ACCOUNT)" \
                          -backend-config="container_name=$(TF_BACKEND_CONTAINER)" \
                          -backend-config="key=guardianlink-dev" \
                          -input=false
                        export GRAFANA_URL="${GRAFANA_ENDPOINT:-https://placeholder.grafana.invalid}"
                        export GRAFANA_AUTH
                        GRAFANA_AUTH=$(az account get-access-token \
                          --resource ce34e7e5-485f-4d76-964f-b3d2b16d1e4f \
                          --query accessToken -o tsv 2>/dev/null || echo "placeholder")
                        terraform destroy -auto-approve -input=false
                    env:
                      TF_VAR_billing_scope_id: $(TF_VAR_billing_scope_id)
                      TF_VAR_alert_email: $(TF_VAR_alert_email)
                      TF_VAR_budget_contact_email: $(TF_VAR_budget_contact_email)
                      TF_VAR_owner: $(TF_VAR_owner)
                      TF_VAR_workload_subscription_id: $(TF_VAR_workload_subscription_id)
                      GRAFANA_ENDPOINT: $(GRAFANA_ENDPOINT)
```

- [ ] **Step 2: Create the `guardianlink-dev` variable group in ADO (manual)**

The template loads three variable groups per stage:
1. `guardianlink-backend` — shared backend storage config (`TF_BACKEND_*`) and ADO bootstrap (`ADO_SETUP_PAT`, `ADO_ORG`, `ADO_PROJECT_ID`). Already exists.
2. `${{ parameters.variableGroup }}` — env-specific TF_VAR_* (per-env values).
3. `guardianlink-infra-outputs` — populated post-apply by the dev pipeline. Already exists.

Create `guardianlink-dev` in ADO → Pipelines → Library with the dev-specific TF_VARs:
- `TF_VAR_billing_scope_id`
- `TF_VAR_alert_email`
- `TF_VAR_budget_contact_email`
- `TF_VAR_owner`
- `TF_VAR_workload_subscription_id`

If these already live in `guardianlink-backend` or `guardianlink-infra-outputs`, copy their values into `guardianlink-dev` and remove from the others (so each variable has one canonical group).

Verify by listing variable groups in the Azure DevOps portal under Pipelines → Library.

- [ ] **Step 3: Diff against the backup to sanity-check**

Run: `diff /tmp/infra.yml.bak pipelines/infra.yml | head -80`
Expected: the dev-side stages collapse into a single template call; the post-apply stage retains the variable-group-update + trigger logic.

- [ ] **Step 4: Commit**

```bash
git add pipelines/infra.yml
git commit -m "refactor(pipelines): collapse dev stages into terraform-env template"
```

---

## Task 10: Add prod template call to pipelines/infra.yml

**Files:**
- Modify: `pipelines/infra.yml`

- [ ] **Step 1: Insert a prod template call after `post_apply_dev`**

In `pipelines/infra.yml`, locate the `apply` branch and add after the `post_apply_dev` stage block (still within `${{ if eq(parameters.action, 'apply') }}:`):

```yaml
    - template: templates/terraform-env.yml
      parameters:
        environment: prod
        tfDir: terraform/environments/prod
        variableGroup: guardianlink-prod
        adoEnvironment: prod
        stateKey: guardianlink-prod
        dependsOn: [post_apply_dev]
```

- [ ] **Step 2: Add prod destroy stage to the destroy branch**

After `destroy_dev`, append within `${{ if eq(parameters.action, 'destroy') }}:`:

```yaml
    - stage: destroy_prod
      displayName: Destroy Prod
      dependsOn: destroy_dev
      condition: succeeded()
      variables:
        - group: guardianlink-backend
        - group: guardianlink-prod
      jobs:
        - deployment: destroy
          displayName: terraform destroy (prod)
          environment: prod
          pool:
            vmImage: ubuntu-latest
          strategy:
            runOnce:
              deploy:
                steps:
                  - checkout: self

                  - template: templates/steps/install-terraform.yml

                  - task: AzureCLI@2
                    displayName: terraform destroy
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      addSpnToEnvironment: true
                      inlineScript: |
                        set -euo pipefail
                        cd terraform/environments/prod
                        export ARM_CLIENT_ID=$servicePrincipalId
                        export ARM_TENANT_ID=$tenantId
                        export ARM_SUBSCRIPTION_ID=$(TF_BACKEND_SUBSCRIPTION_ID)
                        export ARM_USE_OIDC=true
                        export ARM_OIDC_TOKEN=$idToken
                        terraform init \
                          -backend-config="subscription_id=$(TF_BACKEND_SUBSCRIPTION_ID)" \
                          -backend-config="resource_group_name=$(TF_BACKEND_RESOURCE_GROUP)" \
                          -backend-config="storage_account_name=$(TF_BACKEND_STORAGE_ACCOUNT)" \
                          -backend-config="container_name=$(TF_BACKEND_CONTAINER)" \
                          -backend-config="key=guardianlink-prod" \
                          -input=false
                        export GRAFANA_URL="${GRAFANA_ENDPOINT:-https://placeholder.grafana.invalid}"
                        export GRAFANA_AUTH
                        GRAFANA_AUTH=$(az account get-access-token \
                          --resource ce34e7e5-485f-4d76-964f-b3d2b16d1e4f \
                          --query accessToken -o tsv 2>/dev/null || echo "placeholder")
                        # Exclude azurerm_subscription.main from destroy — keeping the
                        # subscription disabled rather than deleted preserves state-key
                        # validity if prod is later re-deployed.
                        terraform state rm azurerm_subscription.main || true
                        terraform destroy -auto-approve -input=false
                    env:
                      TF_VAR_billing_scope_id: $(TF_VAR_billing_scope_id)
                      TF_VAR_alert_email: $(TF_VAR_alert_email)
                      TF_VAR_budget_contact_email: $(TF_VAR_budget_contact_email)
                      TF_VAR_owner: $(TF_VAR_owner)
                      TF_VAR_workload_subscription_id: $(TF_VAR_workload_subscription_id)
                      GRAFANA_ENDPOINT: $(GRAFANA_ENDPOINT)
```

- [ ] **Step 3: Commit**

```bash
git add pipelines/infra.yml
git commit -m "feat(pipelines): add prod environment via template"
```

---

## Task 11: Manual ADO setup — variable group + environment approval gate

**Files:** none (manual ADO config, captured in plan for reproducibility)

- [ ] **Step 1: Create the `guardianlink-prod` variable group**

In ADO → Pipelines → Library → + Variable group → `guardianlink-prod`:

| Name | Value |
|------|-------|
| `TF_BACKEND_SUBSCRIPTION_ID` | (same as dev's backend — backend storage is shared) |
| `TF_BACKEND_RESOURCE_GROUP` | (same as dev) |
| `TF_BACKEND_STORAGE_ACCOUNT` | (same as dev) |
| `TF_BACKEND_CONTAINER` | (same as dev) |
| `TF_VAR_billing_scope_id` | MCA invoice section scope |
| `TF_VAR_alert_email` | prod alert email |
| `TF_VAR_budget_contact_email` | prod budget email |
| `TF_VAR_owner` | owner tag value |
| `TF_VAR_workload_subscription_id` | (empty initially; populate after first Stage 0) |

- [ ] **Step 2: Run Stage 0 once locally to create the prod subscription**

```bash
cd /home/eyal/repos/guardian-link/terraform/environments/prod
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set billing_scope_id and owner; leave workload_subscription_id commented out
az login   # use your billing-scoped account
export ARM_SUBSCRIPTION_ID="<parent subscription with billing rights>"
export TF_BACKEND_RESOURCE_GROUP="<state backend RG>"
export TF_BACKEND_STORAGE_ACCOUNT="<state backend storage account>"
./run.sh stage0 -auto-approve
```

Expected output:
```
Stage 0 complete. Prod subscription_id: <uuid>
```

Capture the printed `subscription_id`.

- [ ] **Step 3: Set `TF_VAR_workload_subscription_id` in the `guardianlink-prod` variable group**

Paste the captured `subscription_id` from Step 2 into the variable group in ADO.

- [ ] **Step 4: Create the `prod` ADO environment with approval gate**

ADO → Pipelines → Environments → New → `prod`. Open it, add Approval check:
- Approvers: your user
- Instructions: "Approve to deploy prod for deploy-verify-destroy validation."
- Timeout: 1 day

- [ ] **Step 5: Verify the dev pipeline still passes**

```bash
cd /home/eyal/repos/guardian-link
git push origin dev   # if executing the plan on a feature branch, push it; if on dev, push as usual
```

Open the pipeline run in ADO. Expected: `validate_dev`, `plan_dev`, `apply_dev`, `post_apply_dev` all green. The `validate_prod` and `plan_prod` stages will run automatically; `apply_prod` will pause on the approval gate.

- [ ] **Step 6: No commit — verification step only**

---

## Task 12: Deploy-verify-destroy prod end-to-end

**Files:** none (validation run)

- [ ] **Step 1: Approve the prod apply stage**

In ADO, click "Review" on the paused `apply_prod` deployment and approve.

- [ ] **Step 2: Watch the prod apply stages complete**

Expected: Stage 1 (Grafana) → import step → Stage 2 (full apply) → green.

If Stage 2 fails on a transient error (e.g. role-assignment propagation), re-run the failed stage from ADO.

- [ ] **Step 3: Verify prod resources via Azure CLI smoke tests**

```bash
PROD_SUB=$(az account list --query "[?name=='guardianlink-prod'].id | [0]" -o tsv)
az account set --subscription "$PROD_SUB"

# IoT Hub reachable
az iot hub show -n iot-guardianlink-prod-weu --query "{name:name, state:properties.state}" -o table

# Cosmos DB account responding
az cosmosdb show -n cosmos-guardianlink-prod-weu -g rg-guardianlink-prod --query "{name:name, state:provisioningState}" -o table

# Event Hubs namespace healthy
az eventhubs namespace show -n evhns-guardianlink-prod-weu -g rg-guardianlink-prod --query "{name:name, state:status}" -o table

# Grafana endpoint loads
GRAFANA_URL=$(cd terraform/environments/prod && terraform output -raw grafana_endpoint)
curl -fsSL -o /dev/null -w "%{http_code}\n" "$GRAFANA_URL" 
```

Expected: All resources `Active` / `Succeeded`, Grafana returns 200 or 302.

If any resource fails to be reachable, capture the error and stop. Do not proceed to destroy until verification passes (or until you've explicitly decided to abandon the prod stack).

- [ ] **Step 4: Run the destroy pipeline against prod**

In ADO, manually queue `infra` pipeline with `action=destroy`. After it completes:

```bash
# Confirm no resources remain in the prod subscription
az resource list --subscription "$PROD_SUB" --query "length(@)"
```

Expected: 0 (or a small number of system-managed resources like default Log Analytics workspace that survive destroy).

- [ ] **Step 5: Confirm the prod subscription itself is preserved**

```bash
az account show --subscription "$PROD_SUB" --query "{name:name, state:state}" -o table
```

Expected: state is `Enabled` or `Warned` (disabled is acceptable too — we removed it from state in destroy_prod, so any cancellation is manual).

- [ ] **Step 6: No commit — validation run only**

If everything passes, the prod environment is validated. Document the verification timestamp by tagging the commit:

```bash
git tag -a prod-validated-$(date +%Y%m%d) -m "Prod deploy-verify-destroy passed"
git push origin --tags
```

---

## Task 13: Update docs/terraform-structure.md

**Files:**
- Modify: `docs/terraform-structure.md`

- [ ] **Step 1: Open the existing terraform-structure.md**

Run: `head -40 docs/terraform-structure.md`

Read the current "Environments" section to identify where prod info should be added.

- [ ] **Step 2: Append a "Prod environment" section after the Environments comparison table**

Add:

```markdown
## Prod environment

The `prod` environment is structured as a flat copy of `dev` (not a module-based composition). It uses its own Azure subscription, created and tracked by Terraform via `azurerm_subscription.main` in `subscription.tf`.

### First-time deploy (Stage 0)

Subscription creation requires Microsoft.Subscription/aliases/write permission, which the ADO service principal does not have. Run Stage 0 once locally with your own `az login`:

```bash
cd terraform/environments/prod
cp terraform.tfvars.example terraform.tfvars
# set billing_scope_id; leave workload_subscription_id commented
./run.sh stage0 -auto-approve
```

Capture the printed subscription ID and set it as `TF_VAR_workload_subscription_id` in the `guardianlink-prod` ADO variable group. Subsequent runs (Stages 1 & 2) authenticate via OIDC and don't need Stage 0 again.

### Why prod retains `azurerm_subscription.main` (dev removes it)

Dev's `subscription.tf` has a `removed` block dropping `azurerm_subscription.main` from state — once the subscription existed, the SP couldn't refresh it, so Terraform stopped managing it. Prod doesn't carry this constraint because Stage 0 runs with user credentials, so the resource stays in state and the subscription's tags/budgets remain Terraform-managed.

### Pipeline template

Both dev and prod stages are produced by the same template at `pipelines/templates/terraform-env.yml`, called from `pipelines/infra.yml` with per-env parameters. The template emits three stages — `validate_<env>`, `plan_<env>`, `apply_<env>` — plus an environment-gated deployment. Add a third environment by adding another `- template:` block in `infra.yml`.

### Deploy-verify-destroy

Prod is not a long-lived environment in this repo's deployment model. The validation pattern is: deploy, run smoke tests against the live stack, then destroy. Subscription is preserved (removed from state before destroy) so state-key reuse on next validation cycle is intact.
```

- [ ] **Step 3: Commit**

```bash
git add docs/terraform-structure.md
git commit -m "docs(terraform): document prod env, Stage 0, pipeline template"
```

---

## Notes for the executor

- **Run on the `dev` branch** of `/home/eyal/repos/guardian-link/`. Merge to `main` only after the full validation in Task 12 passes.
- **The CI/CD definition of done** (per the user's CLAUDE.md): every push to `dev` must result in green ADO pipelines before declaring the task complete. Watch each run.
- **Backup before refactoring** `pipelines/infra.yml` (Task 9 does this) — the rewrite is large.
- **Stage 0 cost note**: creating an Azure subscription is free. Resources deployed in Stages 1-2 will incur charges; minimize the window between Task 12 Step 1 (approve) and Task 12 Step 4 (destroy).
- **If Stage 0 fails with "billing scope not found"**: confirm your local `az` user has `Microsoft.Subscription/aliases/write` on the MCA scope. The ADO SP can't do this — Stage 0 must run locally.
- **Provider cycle gotcha**: if `terraform plan` at any point complains that `local.workload_subscription_id` depends on `azurerm_subscription.main` which is unknown, set `TF_VAR_workload_subscription_id` explicitly to break the cycle. After Stage 0 the variable should always be set.
