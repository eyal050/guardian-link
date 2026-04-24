# Terraform Structure

## Guiding principles

1. **Modules are reusable. Environments are thin.** A module does not know which environment it's deployed to.
2. **No hardcoded names.** Everything composes from a `name_prefix` and resource-specific suffix.
3. **Remote state from day one.** Local state on this is a trap. Use an Azure Storage backend.
4. **One state file per environment.** No cross-environment blast radius.
5. **Plan is boring; apply is deliberate.** Pipelines run `plan` automatically; `apply` requires manual approval even in dev (yes, even in dev — it's interview prep, and fast feedback on mistakes matters).

## Directory layout

```
terraform/
├── modules/
│   ├── core/                    # RG, Log Analytics workspace, App Insights, Key Vault
│   ├── networking/              # VNet, subnets, private DNS (prod only)
│   ├── ingestion/               # IoT Hub, Event Grid/Hubs, Service Bus
│   ├── data/                    # Cosmos DB, Storage Accounts (blob), Postgres
│   ├── compute/                 # Function Apps, Container Apps, App Service Plans
│   ├── api/                     # API Management + products/APIs
│   ├── ml/                      # Container App for the ML stub
│   ├── notifications/           # ACS, Notification Hubs, SendGrid config
│   └── observability/           # dashboards, alerts, action groups
├── envs/
│   ├── dev/
│   │   ├── main.tf              # composes modules
│   │   ├── variables.tf
│   │   ├── terraform.tfvars     # gitignored — real values
│   │   ├── terraform.tfvars.example
│   │   ├── backend.tf           # remote state config
│   │   └── providers.tf
│   └── prod/                    # same shape, different values; may or may not build
└── bootstrap/
    └── state-backend/           # one-time setup: creates the storage account for remote state
```

## Module contract

Every module must:
- Accept `name_prefix`, `location`, `tags` as inputs.
- Accept a `log_analytics_workspace_id` input and wire diagnostic settings to it.
- Output the resource IDs and any secrets (as sensitive) that downstream modules need.
- NOT read from remote state of other modules. Composition happens in `envs/*/main.tf`.

## State backend

```hcl
# bootstrap/state-backend/main.tf — run once, manually, before anything else
resource "azurerm_resource_group" "tfstate" { ... }
resource "azurerm_storage_account" "tfstate" {
  min_tls_version = "TLS1_2"
  # no public access, no shared keys in prod
}
resource "azurerm_storage_container" "tfstate" { ... }
```

Each env's `backend.tf`:
```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-guardianlink-tfstate"
    storage_account_name = "stguardianlinktfstate"
    container_name       = "tfstate"
    key                  = "dev.tfstate"   # or prod.tfstate
  }
}
```

## Naming convention

`{workload}-{env}-{region-short}-{resource-type}` — e.g., `guardianlink-dev-weu-kv-001`.

Exceptions (global-unique resources): storage accounts and Key Vaults get a short random suffix because the name pool is global.

## Tagging

Every resource, no exceptions:
```hcl
tags = {
  workload    = "guardianlink"
  environment = var.environment
  managed_by  = "terraform"
  cost_center = "interview-prep"
  owner       = "<your name>"
}
```

## Secret handling

- Terraform never writes real secrets to state in plaintext if avoidable.
- The SendGrid key and ACS connection string are created in Key Vault manually OR injected via pipeline variables; Terraform references them by Key Vault secret ID, not value.
- Outputs that contain secrets are marked `sensitive = true`.
- `terraform.tfvars` is gitignored. A `.example` version lives in git with fake values.

## Environments

- **dev** — single region (West Europe), minimal redundancy, public endpoints with firewall rules, Cosmos serverless or low autoscale, Postgres B-series, everything sized for cost.
- **prod** (optional) — same region to start, but with private endpoints, zone redundancy on Postgres, Cosmos dedicated throughput, APIM Developer tier (Premium is out of scope for prep cost).

**Realistic cost warning:** Even "dev" sized, this is not free. APIM alone is €50–100/month on Developer tier. IoT Hub has a free tier (8000 msg/day) — stay in it. Budget **€100–200/month max** for the full stack running continuously; destroy environments when not actively working on them.

## Pipeline integration

```
pipelines/
└── azure-pipelines.yml
    stages:
      - stage: Validate
          jobs: fmt check, validate, tflint, tfsec
      - stage: Plan
          jobs: terraform plan -out=tfplan; publish artifact
      - stage: Apply
          condition: manual approval
          jobs: terraform apply tfplan
```

Pipeline authenticates via Azure DevOps service connection with workload identity federation — no secrets stored in pipeline variables.

## What Claude Code should do first

1. Scaffold `bootstrap/state-backend/` and walk the user through running it once manually.
2. Scaffold `modules/core/` — RG, Log Analytics, App Insights, Key Vault.
3. Scaffold `envs/dev/` that uses only the `core` module, plus the backend config.
4. Get `terraform init && terraform plan && terraform apply` green on that minimal footprint.
5. Stop. Wait for user review before adding the next module.

**Do not generate all modules at once.** Incremental builds are the point. The user learns more from 10 small applies than from 1 big one.
