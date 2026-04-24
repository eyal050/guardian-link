# Terraform Structure

## Guiding principles

1. **Environment = subscription.** Each (application, environment) pair gets its own Azure subscription, provisioned by its own Terraform stack. Blast radius stops at the subscription boundary; there is no cross-env IAM to get wrong.
2. **Flat root per stack.** No `modules/` + `envs/` split for this project. The resource count per stack does not yet justify the abstraction. If two stacks grow enough duplicated HCL to make modules worthwhile, refactor then — not speculatively.
3. **Remote state, externally bootstrapped.** A shared state storage account (`eyaltfstorage22042026` in `rg-terraform-state-dev`, in a parent subscription) exists outside this repo. Each stack keys into it as `{application}-{environment}`. That storage account is not managed by guardianlink Terraform.
4. **Two providers per stack.** The default `azurerm` provider points at the parent subscription (via `ARM_SUBSCRIPTION_ID` in the environment) and is used only to create the child subscription. An aliased `azurerm.workload` provider targets the child sub. Every workload resource explicitly sets `provider = azurerm.workload` — forgetting that line lands the resource in the parent sub, which is the main footgun of this model.
5. **No secrets in code or tfvars.** Once a Key Vault exists, secrets live there; Terraform references them by secret ID. Outputs that carry credentials are `sensitive = true`.
6. **Apply is deliberate.** Even in dev, `terraform apply` is a manual step; pipelines (when added) run `plan` automatically but gate `apply` on approval.

## Directory layout

```
terraform/
└── guardianlink-dev/         # one flat stack per (app, env)
    ├── versions.tf           # required_providers + empty backend block + provider aliases
    ├── subscription.tf       # azurerm_subscription + optional MG association
    ├── rg.tf                 # resource group in the new sub
    ├── budget.tf             # monthly consumption budget + threshold alerts
    ├── observability.tf      # Log Analytics workspace + App Insights
    ├── eventgrid.tf          # Event Grid custom topic(s) + diagnostic settings
    ├── locals.tf             # tags map, name_prefix, region-short lookup
    ├── variables.tf
    ├── terraform.tfvars.example   # committed template
    ├── terraform.tfvars           # gitignored, real values
    └── run.sh                # init wrapper; injects backend-config
```

A `guardianlink-prod/` stack, if built, sits alongside with the same shape and a separate subscription. Stacks do not read each other's state.

`tf-lab-boilerplate/` at the repo root is the generic new-subscription starter this stack was derived from. It is not deployed.

## State backend (external, not managed here)

Each stack's `versions.tf` declares an empty `backend "azurerm" {}` block; the config is injected at `terraform init` time via `-backend-config` flags so the same TF can point at different state blobs per stack. `run.sh` encapsulates that:

```
resource_group_name  = "rg-terraform-state-dev"
storage_account_name = "eyaltfstorage22042026"
container_name       = "tfstate"
key                  = "{application}-{environment}"    # e.g. guardianlink-dev
```

The state key is hardcoded in each stack's `run.sh` to match its directory name. Renaming the directory without updating `run.sh` points it at the wrong state — do both or neither.

## Provider model

```hcl
provider "azurerm" {
  features {}
  # parent sub (ARM_SUBSCRIPTION_ID); creates child sub only
}

provider "azurerm" {
  alias           = "workload"
  subscription_id = azurerm_subscription.main.subscription_id
  features {}
}
```

Every workload resource sets `provider = azurerm.workload` explicitly. The subscription, budget, and MG-association resources are the exceptions (the sub itself is created by the default provider; the budget and MG association operate on the child sub but are created from the parent-sub context).

## Naming convention

`{caf-prefix}-{application}-{environment}-{region-short}[-{qualifier}]`

Where `{caf-prefix}` is the Microsoft CAF abbreviation for the resource type. Examples:

| Resource type            | CAF prefix | Example                                   |
|--------------------------|------------|-------------------------------------------|
| Resource group           | `rg`       | `rg-guardianlink-dev` (RG has location field, no region in name) |
| Log Analytics workspace  | `log`      | `log-guardianlink-dev-weu`                |
| Application Insights     | `appi`     | `appi-guardianlink-dev-weu`               |
| Event Grid custom topic  | `evgt`     | `evgt-guardianlink-dev-weu-lifecycle`     |
| Event Hubs namespace     | `evhns`    | `evhns-guardianlink-dev-weu`              |
| Service Bus namespace    | `sbns`     | `sbns-guardianlink-dev-weu`               |
| IoT Hub                  | `iot`      | `iot-guardianlink-dev-weu`                |
| Cosmos DB account        | `cosmos`   | `cosmos-guardianlink-dev-weu`             |
| Key Vault                | `kv`       | `kv-gl-dev-weu-<rand>` (globally unique)  |
| Storage account          | `st`       | `stgldev<rand>` (globally unique, lower, no dashes) |

Globally-unique-name resources (storage accounts, Key Vaults) get a short `random_string` suffix; add it when those resources are added.

The name_prefix is composed once in `locals.tf`:
```hcl
local.name_prefix = "${var.application_name}-${var.environment_name}-${local.location_short}"
```

## Tagging

Defined once in `locals.tf`, applied to every resource that supports tags:

```hcl
tags = {
  workload    = var.application_name
  environment = var.environment_name
  managed_by  = "terraform"
  cost_center = "interview-prep"
  owner       = var.owner
}
```

`azurerm_consumption_budget_subscription` does not support tags. That's the exception.

## Cost guardrail

Every stack includes an `azurerm_consumption_budget_subscription` with:
- 50% actual-spend email alert
- 80% forecast-spend email alert

Default amount is €100/mo for dev. Run `terraform destroy` on the stack when not in active use — the external state backend persists, so the stack can be rebuilt fresh from `terraform apply`.

## Secret handling

- No secret values in `*.tf` or `*.tfvars`.
- Once a Key Vault exists, service-created secrets (SendGrid, ACS, etc.) live there; Terraform references by `azurerm_key_vault_secret.id`.
- Function Apps and Container Apps pull Key Vault references at runtime via managed identity — never by connection string.
- Sensitive outputs are marked `sensitive = true`.
- `terraform.tfvars` is gitignored (`.gitignore` negates `!*.tfvars.example` so the template is committed).

## Environments

- **dev** — single region (West Europe), public endpoints with firewall rules, Cosmos serverless or low autoscale, Postgres B-series. Sized for cost.
- **prod** (optional, not built) — same region initially, private endpoints, zone redundancy, dedicated Cosmos throughput. Not in scope unless explicitly added.

**Cost warning:** €100–200/month is a realistic ceiling for the full stack running continuously in dev. Destroy when not in use.

## Pipeline integration (not built yet)

When added:
- Validate: `terraform fmt -check`, `terraform validate`, `tflint`, `tfsec`.
- Plan: `terraform plan -out=tfplan`; publish artifact.
- Apply: manual approval gate, then `terraform apply tfplan`.

Auth via Azure DevOps service connection with workload identity federation — no secrets in pipeline variables.

## What to build next

Rhythm: one resource area per apply, verify in the portal, commit, agree next slice.

Current state of `guardianlink-dev`: subscription + RG + budget + Log Analytics + App Insights + Event Grid custom topic (`lifecycle`) + its diagnostic settings.

Candidate next slices (pick one per session):
- **Key Vault** — prerequisite for any service that needs a stored secret.
- **Storage account** — raw/cold telemetry blob; also needed before Event Grid system topics.
- **Event Hubs namespace + hub** — device telemetry stream.
- **Service Bus namespace + queue** — crash notification pipeline.
- **IoT Hub** — device ingestion, routes to Event Hubs.

Do not scaffold more than one area per apply without explicit scope agreement.
