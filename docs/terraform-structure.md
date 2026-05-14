# Terraform Structure

## Guiding principles

1. **Environment = subscription.** Each (application, environment) pair gets its own Azure subscription, provisioned by its own Terraform stack. Blast radius stops at the subscription boundary; there is no cross-env IAM to get wrong.
2. **Reusable modules, flat environment roots.** Shared infrastructure patterns live in `terraform/modules/`. Each environment root (`environments/{env}/`) calls those modules and owns its own provider config, backend config, and environment-specific overrides (partition counts, retention, SKUs).
3. **Remote state, externally bootstrapped.** A shared state storage account exists outside this repo. Each stack keys into it as `guardianlink-{environment}`. That account is not managed by guardianlink Terraform.
4. **Two providers per stack root.** The default `azurerm` provider points at the parent subscription (via `ARM_SUBSCRIPTION_ID`). An aliased `azurerm.workload` provider targets the child subscription. Every workload resource sets `provider = azurerm.workload`. Modules receive the alias via a `providers` map in the module call — never from ambient state.
5. **No secrets in code or tfvars.** Once a Key Vault exists, secrets live there. Outputs carrying credentials are `sensitive = true`.
6. **Apply is deliberate.** `terraform apply` is always gated on a manual approval in the pipeline. `plan` runs automatically on every push.

---

## Directory layout

```
terraform/
├── environments/
│   ├── dev/                  # deployed; full flat stack (module migration in progress)
│   │   ├── versions.tf       # providers + backend block
│   │   ├── locals.tf         # name_prefix, tags
│   │   ├── variables.tf
│   │   ├── *.tf              # one file per resource area
│   │   ├── terraform.tfvars.example
│   │   └── run.sh            # local init wrapper; injects backend-config
│   ├── staging/              # stub — not deployed; shows module consumption pattern
│   │   ├── versions.tf
│   │   ├── variables.tf
│   │   └── main.tf           # calls modules with staging-specific overrides
│   └── prod/                 # flat stack — deployed under guardianlink-prod sub
│       ├── versions.tf, variables.tf, locals.tf
│       ├── subscription.tf   # azurerm_subscription.main kept in state (unlike dev)
│       ├── *.tf              # resource definitions (mirrors dev)
│       ├── terraform.tfvars.example
│       └── run.sh            # three-mode wrapper: stage0 | apply | passthrough
└── modules/
    ├── observability/         # Log Analytics workspace + App Insights (fully extracted)
    │   ├── versions.tf        # configuration_aliases = [azurerm.workload]
    │   ├── variables.tf
    │   ├── main.tf
    │   └── outputs.tf
    ├── iot/                   # IoT Hub + identity-based routing to Event Hubs
    │   ├── versions.tf
    │   ├── variables.tf
    │   ├── main.tf
    │   └── outputs.tf
    ├── eventhub/              # Event Hubs namespace + telemetry hub
    │   ├── versions.tf
    │   ├── variables.tf
    │   ├── main.tf
    │   └── outputs.tf
    ├── servicebus/            # Service Bus namespace + crash-confirmed queue
    │   ├── versions.tf
    │   ├── variables.tf
    │   ├── main.tf
    │   └── outputs.tf
    └── functions/             # Function Apps (telemetry-writer, classifier, notifier, metrics)
        ├── versions.tf
        ├── variables.tf
        ├── main.tf
        └── outputs.tf
```

---

## Module pattern

Modules use `configuration_aliases` to receive the workload provider from the calling environment:

```hcl
# modules/observability/versions.tf
terraform {
  required_providers {
    azurerm = {
      source                = "hashicorp/azurerm"
      configuration_aliases = [azurerm.workload]
    }
  }
}
```

```hcl
# environments/staging/main.tf
module "observability" {
  source = "../../modules/observability"

  providers = {
    azurerm.workload = azurerm.workload
  }

  name_prefix         = local.name_prefix
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name
  log_retention_days  = 30
  tags                = local.tags
}
```

Module outputs wire into the next module's variables — e.g. `module.observability.workspace_id` feeds into `module.iot.log_analytics_workspace_id`. This makes cross-module dependencies explicit and lint-checkable.

---

## Migrating environments/dev to modules

`environments/dev/` still uses the original flat layout for operational stability. Migrating each resource area requires `terraform state mv` to update state addresses:

```bash
# Example: migrating observability resources
terraform state mv \
  azurerm_log_analytics_workspace.main \
  module.observability.azurerm_log_analytics_workspace.main

terraform state mv \
  azurerm_application_insights.main \
  module.observability.azurerm_application_insights.main
```

Run `terraform plan` after each `state mv` to confirm zero diff before moving on.

---

## Environment comparison

| Concern | dev | staging | prod |
|---|---|---|---|
| Subscription | dedicated | dedicated | dedicated |
| Cosmos capacity | serverless | serverless | provisioned autoscale |
| Event Hub partitions | 4 | 4 | 8 |
| Log retention | 30 days | 30 days | 90 days |
| Private endpoints | no | no | yes |
| Grafana | yes | optional | yes |
| Budget alert | €100/mo | €200/mo | €500/mo |
| Apply gate | ADO `dev` environment approval | ADO `staging` environment approval | ADO `prod` environment approval + second engineer sign-off |

---

## State backend

Each stack declares an empty `backend "azurerm" {}` block; config is injected at `terraform init` time:

```
resource_group_name  = "<tf-state-resource-group>"
storage_account_name = "<tf-state-storage-account>"
container_name       = "tfstate"
key                  = "guardianlink-{environment}"
```

State keys: `guardianlink-dev`, `guardianlink-staging`, `guardianlink-prod`. The keys are fixed in each environment's `run.sh` and pipeline — renaming an environment requires updating both the key and the directory, or state is orphaned.

---

## Provider model

```hcl
# environments/*/versions.tf
provider "azurerm" {
  features {}
  # authenticates against parent sub (ARM_SUBSCRIPTION_ID) — creates child sub only
}

provider "azurerm" {
  alias           = "workload"
  subscription_id = var.workload_subscription_id
  features {}
}
```

Every workload resource sets `provider = azurerm.workload`. Modules inherit it via the `providers` map. Forgetting `provider = azurerm.workload` silently lands the resource in the parent subscription.

---

## Naming convention

`{caf-prefix}-{application}-{environment}-{region-short}[-{qualifier}]`

| Resource type | CAF prefix | Example |
|---|---|---|
| Resource group | `rg` | `rg-guardianlink-dev` |
| Log Analytics workspace | `log` | `log-guardianlink-dev-weu` |
| Application Insights | `appi` | `appi-guardianlink-dev-weu` |
| Event Hubs namespace | `evhns` | `evhns-guardianlink-dev-weu` |
| Service Bus namespace | `sbns` | `sbns-guardianlink-dev-weu` |
| IoT Hub | `iot` | `iot-guardianlink-dev-weu` |
| Cosmos DB account | `cosmos` | `cosmos-guardianlink-dev-weu` |
| Key Vault | `kv` | `kv-gl-dev-weu-<rand>` (globally unique) |
| Storage account | `stgl` | `stgldev<rand>` (globally unique, lowercase, no dashes) |

`local.name_prefix` is composed once in `locals.tf`:
```hcl
name_prefix = "${var.application_name}-${var.environment_name}-${local.location_short}"
```

---

## Cost guardrail

Every stack includes a budget with 50% actual and 80% forecast email alerts. Default: €100/month for dev.

Run `terraform destroy` when not in active use — the remote state persists, so the stack can be rebuilt from `terraform apply`.

---

## Prod environment

Prod is a flat copy of dev (not module-based composition). It owns its own subscription, `guardianlink-prod`, created and tracked by Terraform via `azurerm_subscription.main` in `subscription.tf`.

### First-time deploy (Stage 0)

Subscription creation requires `Microsoft.Subscription/aliases/write` on the billing scope. The ADO service principal does not have it. Run Stage 0 once locally with your own `az login`:

```bash
cd terraform/environments/prod
cp terraform.tfvars.example terraform.tfvars
# set billing_scope_id; leave workload_subscription_id commented
./run.sh stage0 -auto-approve
```

The script prints the new `subscription_id`. Paste it as `TF_VAR_workload_subscription_id` in the `guardianlink-prod` ADO variable group. Subsequent runs (Stages 1 & 2) authenticate via OIDC and don't need Stage 0 again.

### Why prod mirrors dev's `removed` block pattern

Stage 0 creates the subscription with the user's own `az login` credentials, then the pipeline takes over for everything inside the subscription. The ADO service principal lacks `Microsoft.Subscription/aliases/*` permissions, so any subsequent pipeline plan that tried to refresh `azurerm_subscription.main` would fail with 401. The `removed` block in `subscription.tf` (same pattern as dev) takes the resource out of Terraform's management surface after the bootstrap — the subscription stays alive in Azure, the pipeline stops touching it, and the workload provider authenticates via `var.workload_subscription_id` only.

### Pipeline template

Both dev and prod stages are produced by `pipelines/templates/terraform-env.yml`, called from `pipelines/infra.yml` with per-env parameters (`environment`, `tfDir`, `variableGroup`, `adoEnvironment`, `stateKey`). The template emits three stages — `validate_<env>`, `plan_<env>`, `apply_<env>` — plus an environment-gated deployment job. Adding a third environment is one more `- template:` block in `infra.yml` plus a matching variable group.

### Deploy-verify-destroy

Prod is not long-lived in this repo's deployment model. The validation pattern is: deploy, run smoke tests against the live stack, then destroy. The destroy stage removes `azurerm_subscription.main` from state before `terraform destroy`, so the subscription itself is preserved (disabled rather than deleted) and the state key remains valid for the next cycle.
