# Terraform Prod Environment & Pipeline Template Design

**Date:** 2026-05-13  
**Status:** Approved  
**Scope:** Phase 2.3 prerequisite — validate multi-environment Terraform workflow before AKS work

---

## 1. Architecture

**Approach:** Copy dev flat stack to `terraform/environments/prod/`. No shared module consumption yet — the modules created in Phase 2.1 exist as a refactoring artifact; dev/prod both use the flat resource layout. This keeps the prod stack simple and directly reviewable.

**Two subscriptions only:**
- `guardianlink-dev` — existing, managed by dev environment
- `guardianlink-prod` — new, created by Terraform in the prod environment

**Key difference from dev:** Prod retains `azurerm_subscription.main` in Terraform state. Dev had this resource removed because the ADO service principal lacked `Microsoft.Subscription/aliases/write`. Prod subscription creation runs in a Stage 0 that uses the user's own CLI credentials (`az login`), not the ADO SP.

**Resource naming:** Prod resources use the `gl` prefix with `-prod` suffix (e.g., `gl-eventhub-prod`).  
**Resource groups:** `gl-core-prod`, `gl-observability-prod`, `gl-iot-prod`.

---

## 2. Pipeline

### Template: `pipelines/templates/terraform-env.yml`

A parametrised ADO pipeline template called by `infra.yml` for both dev and prod. Parameters:

| Parameter | Purpose |
|-----------|---------|
| `environment` | Display label (dev / prod) |
| `tfDir` | Terraform working directory (e.g. `terraform/environments/dev`) |
| `variableGroup` | ADO variable group name |
| `adoEnvironment` | ADO environment resource for approval gates |
| `stateKey` | Backend state key (e.g. `guardianlink-prod`) |
| `dependsOn` | Stage dependency list (default: `[]`) |

The template contains the full Terraform stage logic — install, init, plan, Grafana-first apply (Stage 1), full apply (Stage 2). `infra.yml` becomes a thin orchestrator that calls the template twice.

### `pipelines/infra.yml` after refactor

```yaml
stages:
  - template: templates/terraform-env.yml
    parameters:
      environment: dev
      tfDir: terraform/environments/dev
      variableGroup: guardianlink-dev
      adoEnvironment: dev
      stateKey: guardianlink-dev

  - template: templates/terraform-env.yml
    parameters:
      environment: prod
      tfDir: terraform/environments/prod
      variableGroup: guardianlink-prod
      adoEnvironment: prod          # manual approval gate configured in ADO
      stateKey: guardianlink-prod
      dependsOn: [deploy_dev]
```

Prod stage requires manual approval via ADO environment gate before running.

---

## 3. Prod Terraform Layout

### `terraform/environments/prod/`

```
subscription.tf      — azurerm_subscription.main (creates guardianlink-prod sub)
providers.tf         — root + workload provider aliases
backend.tf           — stateKey = "guardianlink-prod"
variables.tf         — same vars as dev; workload_subscription_id defaults to null
locals.tf            — resolves subscription_id from subscription output or variable
main.tf              — all resources (same flat layout as dev, prod-sized config)
outputs.tf
terraform.tfvars.example
run.sh
```

### Subscription creation (`subscription.tf`)

```hcl
resource "azurerm_subscription" "main" {
  subscription_name = "guardianlink-prod"
  billing_scope_id  = var.billing_scope_id
  tags              = local.tags
}
```

### Optional `workload_subscription_id` via locals

```hcl
locals {
  subscription_id = (
    var.workload_subscription_id != null
      ? var.workload_subscription_id
      : azurerm_subscription.main.subscription_id
  )
}
```

All resources use `local.subscription_id` rather than `var.workload_subscription_id` directly.

### Three-stage `run.sh`

- **Stage 0** — `terraform apply -target=azurerm_subscription.main` (run once, with user's `az login` credentials; captures subscription ID into state)
- **Stage 1** — Grafana-first apply (same as dev Stage 1: `-target` Grafana resources)
- **Stage 2** — `terraform apply` (full apply)

Stage 0 is commented out after first run with a note: "subscription exists in state, skip."

---

## 4. Deploy-Verify-Destroy Workflow

Purpose: validate the prod Terraform stack is correct without incurring ongoing Azure costs.

1. **Deploy** — run prod stages (Stage 0 → Stage 1 → Stage 2); confirm all resources created
2. **Verify** — smoke-test key resources: IoT Hub reachable, Cosmos DB responding, Event Hubs namespace healthy, Grafana dashboard loads
3. **Destroy** — `terraform destroy` prod; confirm subscription charges stop
4. **Keep subscription** — `azurerm_subscription.main` resource is not destroyed (remove from state before destroy, or use `-target` exclusion); subscription is disabled rather than deleted so state key remains valid if re-deployed later

The ADO pipeline for destroy is a manual trigger job in the prod stage, gated behind a second ADO environment approval.

---

## 5. What This Is Not

- Not migrating dev resources to use modules (modules exist as a showcase; dev keeps flat layout)
- Not permanently running a prod environment (deploy-verify-destroy, not long-lived)
- Not AKS — that is Phase 2.3 and happens after this validation passes
