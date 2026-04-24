# Event Hubs slice — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Event Hubs namespace with a single `telemetry` hub and diagnostic settings to the `guardianlink-dev` Terraform stack, so the device telemetry backbone is in place for a later IoT Hub slice to route to.

**Architecture:** One new file `terraform/guardianlink-dev/eventhubs.tf` containing three resources: `azurerm_eventhub_namespace`, `azurerm_eventhub`, `azurerm_monitor_diagnostic_setting`. All on the aliased `azurerm.workload` provider (child subscription). No new variables. No `locals.tf` changes. Naming follows the existing `local.name_prefix`. Diagnostic-setting shape mirrors `eventgrid.tf`. Spec: `docs/superpowers/specs/2026-04-24-eventhubs-slice-design.md`.

**Tech Stack:** Terraform (`azurerm` provider), Azure CLI for post-apply verification. No application code, no pipeline.

**Stack-specific mechanics:**
- `./run.sh <cmd>` wraps `terraform init` with backend config and exports `ARM_SUBSCRIPTION_ID`. Use it for every `plan` / `apply` / `fmt` / `validate` command (it passes `"$@"` through).
- Every workload resource MUST set `provider = azurerm.workload` — forgetting that line lands the resource in the parent subscription.
- The state backend is external and persistent; `terraform destroy` on this stack is safe between sessions.

**Testing approach:** There is no unit-test framework for Terraform in this repo. Each task validates by `terraform fmt`, `terraform validate`, and `./run.sh plan` producing the expected number and type of resource additions. Post-apply verification uses `az` CLI against the child subscription. That is the test loop — no `pytest`/`go test`/`npm test` apply.

---

## File Structure

- **Create:** `terraform/guardianlink-dev/eventhubs.tf` — all three resources for this slice.
- **Modify:** none.
- **Already exists and referenced:** `rg.tf` (`azurerm_resource_group.main`), `observability.tf` (`azurerm_log_analytics_workspace.main`), `locals.tf` (`local.name_prefix`, `local.tags`), `variables.tf` (`var.primary_location`).

---

## Task 1: Create eventhubs.tf with the namespace resource

**Files:**
- Create: `terraform/guardianlink-dev/eventhubs.tf`

- [ ] **Step 1: Create `eventhubs.tf` containing only the namespace**

Write this exact content to `terraform/guardianlink-dev/eventhubs.tf`:

```hcl
# Event Hubs namespace for the device-telemetry streaming backbone.
#
# local_authentication_enabled = false: producers/consumers authenticate
# via Entra ID (e.g., IoT Hub routes using system-assigned identity +
# Azure Event Hubs Data Sender role). No SAS keys to rotate or leak.
#
# Standard SKU is required for >1 consumer group and 7-day retention.
# Auto-inflate bounded at 2 TU to cap dev cost.
resource "azurerm_eventhub_namespace" "main" {
  provider = azurerm.workload

  name                = "evhns-${local.name_prefix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name

  sku                      = "Standard"
  capacity                 = 1
  auto_inflate_enabled     = true
  maximum_throughput_units = 2

  public_network_access_enabled = true
  local_authentication_enabled  = false
  minimum_tls_version           = "1.2"

  tags = local.tags
}
```

- [ ] **Step 2: Format and validate**

Run from `terraform/guardianlink-dev/`:
```bash
terraform fmt
./run.sh validate
```
Expected: `fmt` emits nothing (or normalizes whitespace); `validate` prints `Success! The configuration is valid.`

- [ ] **Step 3: Plan and inspect**

```bash
./run.sh plan
```
Expected: plan shows exactly **1 resource to add** (`azurerm_eventhub_namespace.main`), 0 to change, 0 to destroy. Skim the output:
- `name = "evhns-guardianlink-dev-weu"`
- `sku = "Standard"`, `capacity = 1`, `auto_inflate_enabled = true`, `maximum_throughput_units = 2`
- `local_authentication_enabled = false`, `public_network_access_enabled = true`, `minimum_tls_version = "1.2"`

Note: `zone_redundant` is not in the HCL — it was removed from `azurerm_eventhub_namespace` in azurerm 4.x. Standard SKU in AZ-enabled regions is zone-redundant by platform default; post-apply the resource will report `zoneRedundant = true` without any HCL asking for it.

If any value is off, fix the HCL and re-plan before moving on.

---

## Task 2: Add the `telemetry` hub

**Files:**
- Modify: `terraform/guardianlink-dev/eventhubs.tf` (append)

- [ ] **Step 1: Append the hub resource**

Append this block to `terraform/guardianlink-dev/eventhubs.tf`:

```hcl
# Single hub for device telemetry. Partitioned by deviceId at the producer
# (IoT Hub route or Function); 4 partitions = 4 max parallel consumers per
# group. Partition count can grow but not shrink on Standard, so this is a
# sticky choice. 7-day retention supports classifier replay over a past
# window. No Capture: the telemetry-writer Function will write raw batches
# to Blob when that slice lands.
resource "azurerm_eventhub" "telemetry" {
  provider = azurerm.workload

  name                = "telemetry"
  namespace_name      = azurerm_eventhub_namespace.main.name
  resource_group_name = azurerm_resource_group.main.name

  partition_count   = 4
  message_retention = 7
}
```

- [ ] **Step 2: Format and validate**

```bash
terraform fmt
./run.sh validate
```
Expected: both clean.

- [ ] **Step 3: Plan and inspect**

```bash
./run.sh plan
```
Expected: plan shows exactly **2 resources to add** (`azurerm_eventhub_namespace.main`, `azurerm_eventhub.telemetry`), 0 to change, 0 to destroy.
- On `azurerm_eventhub.telemetry`: `name = "telemetry"`, `partition_count = 4`, `message_retention = 7`.

---

## Task 3: Add the diagnostic setting

**Files:**
- Modify: `terraform/guardianlink-dev/eventhubs.tf` (append)

- [ ] **Step 1: Append the diagnostic setting**

Append this block to `terraform/guardianlink-dev/eventhubs.tf`:

```hcl
# Route namespace (and hub-level, which bubbles up) logs + metrics to the
# shared Log Analytics workspace. Categories selected for this config:
# - OperationalLogs  : namespace/hub CRUD + config changes
# - AutoScaleLogs    : records every TU inflation event (auto_inflate_enabled)
# - RuntimeAuditLogs : authentication attempts (relevant: local auth disabled)
# - ArchiveLogs      : Capture-related; empty today, harmless when Capture lands
# Kafka/CMK/VNet categories omitted — not in use for this slice.
resource "azurerm_monitor_diagnostic_setting" "eventhub_namespace" {
  provider = azurerm.workload

  name                       = "diag-evhns-${local.name_prefix}"
  target_resource_id         = azurerm_eventhub_namespace.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "OperationalLogs"
  }

  enabled_log {
    category = "AutoScaleLogs"
  }

  enabled_log {
    category = "RuntimeAuditLogs"
  }

  enabled_log {
    category = "ArchiveLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
```

- [ ] **Step 2: Format and validate**

```bash
terraform fmt
./run.sh validate
```
Expected: both clean.

- [ ] **Step 3: Plan and inspect**

```bash
./run.sh plan
```
Expected: plan shows exactly **3 resources to add** (namespace, hub, diagnostic setting), 0 to change, 0 to destroy. On the diagnostic setting:
- `name = "diag-evhns-guardianlink-dev-weu"`
- `target_resource_id` references the new namespace
- `log_analytics_workspace_id` references the existing `azurerm_log_analytics_workspace.main`
- four `enabled_log` blocks (OperationalLogs, AutoScaleLogs, RuntimeAuditLogs, ArchiveLogs)
- one `metric` block, `AllMetrics`, enabled

If the plan tries to modify anything other than the three new resources, STOP — that means drift was introduced elsewhere. Investigate before applying.

---

## Task 4: Apply

**Files:** none modified in this task.

- [ ] **Step 1: Apply**

```bash
./run.sh apply
```
Enter `yes` at the confirmation prompt.

Expected: `Apply complete! Resources: 3 added, 0 changed, 0 destroyed.` Apply typically takes 1–3 minutes (namespace creation is the slow part).

- [ ] **Step 2: Confirm no drift**

```bash
./run.sh plan
```
Expected: `No changes. Your infrastructure matches the configuration.`

If plan reports changes, record them and stop — something in the HCL is not idempotent.

---

## Task 5: Post-apply verification via Azure CLI

**Files:** none.

All `az` commands below must run against the **child subscription**. Switch to it explicitly — the parent sub will not contain any of these resources and commands will 404 misleadingly.

```bash
# The child sub's display name comes from var.new_subscription_name in
# terraform.tfvars. Look it up and switch:
CHILD_SUB_ID=$(terraform output -raw subscription_id 2>/dev/null \
  || az account list --query "[?name=='$(grep new_subscription_name terraform.tfvars | cut -d'"' -f2)'].id" -o tsv)
az account set --subscription "$CHILD_SUB_ID"
az account show --query "{name:name, id:id}" -o table   # sanity check
```
If `terraform output subscription_id` isn't defined in this stack, use only the `az account list` fallback. The rest of the task assumes the active subscription is the child.

- [ ] **Step 1: Verify namespace config**

```bash
az eventhubs namespace show \
  -g "rg-guardianlink-dev" \
  -n "evhns-guardianlink-dev-weu" \
  --query "{sku:sku.name, capacity:sku.capacity, autoInflate:isAutoInflateEnabled, maxTu:maximumThroughputUnits, localAuthDisabled:disableLocalAuth, publicAccess:publicNetworkAccess, tls:minimumTlsVersion, zoneRedundant:zoneRedundant}" \
  -o table
```

Expected:
- `Sku = Standard`
- `Capacity = 1`
- `AutoInflate = True`
- `MaxTu = 2`
- `LocalAuthDisabled = True` (Azure stores the inverse of Terraform's `local_authentication_enabled = false`)
- `PublicAccess = Enabled`
- `Tls = 1.2`
- `ZoneRedundant = True` (platform default on Standard in `westeurope` — not a user-set value; azurerm 4.x removed the `zone_redundant` argument)

- [ ] **Step 2: Verify hub config**

```bash
az eventhubs eventhub show \
  -g "rg-guardianlink-dev" \
  --namespace-name "evhns-guardianlink-dev-weu" \
  -n "telemetry" \
  --query "{partitions:partitionCount, retention:messageRetentionInDays, status:status}" \
  -o table
```

Expected: `Partitions = 4`, `Retention = 7`, `Status = Active`.

- [ ] **Step 3: Verify diagnostic setting wiring**

```bash
NS_ID=$(az eventhubs namespace show \
  -g "rg-guardianlink-dev" \
  -n "evhns-guardianlink-dev-weu" \
  --query id -o tsv)

az monitor diagnostic-settings list --resource "$NS_ID" \
  --query "[].{name:name, workspace:workspaceId, logs:logs[?enabled].category, metrics:metrics[?enabled].category}" \
  -o json
```

Expected output contains one entry:
- `name = "diag-evhns-guardianlink-dev-weu"`
- `workspace` ends with `/providers/Microsoft.OperationalInsights/workspaces/log-guardianlink-dev-weu`
- `logs` contains exactly: `OperationalLogs`, `AutoScaleLogs`, `RuntimeAuditLogs`, `ArchiveLogs`
- `metrics` contains `AllMetrics`

- [ ] **Step 4: (Optional, delayed) Confirm log ingestion**

Wait ~5 minutes after apply, then in the Log Analytics workspace (portal → Logs) run:
```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.EVENTHUB"
| take 10
```
Even with no traffic, operational/metric rows should eventually appear. Absence is not a failure of this slice — it only means no qualifying events have fired yet. Do not block on this step.

---

## Task 6: Commit spec + Terraform together

**Files:**
- Stage: `docs/superpowers/specs/2026-04-24-eventhubs-slice-design.md`
- Stage: `docs/superpowers/plans/2026-04-24-eventhubs-slice.md`
- Stage: `terraform/guardianlink-dev/eventhubs.tf`

Per project preference, the design spec was held uncommitted during this slice and lands in the same commit as the Terraform.

- [ ] **Step 1: Stage the exact files (no `git add -A`)**

```bash
git add \
  docs/superpowers/specs/2026-04-24-eventhubs-slice-design.md \
  docs/superpowers/plans/2026-04-24-eventhubs-slice.md \
  terraform/guardianlink-dev/eventhubs.tf
```

- [ ] **Step 2: Confirm staged set matches expectation**

```bash
git status --short
```
Expected: exactly three lines prefixed `A ` (staged-added) for the files above; nothing else staged. If `terraform.tfvars` or `.failure-state/` appears staged, `git restore --staged <file>` before committing.

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(terraform): add Event Hubs namespace + telemetry hub

Adds evhns-guardianlink-dev-weu (Standard, 1→2 TU auto-inflate, Entra-only
auth, public network) with a single 4-partition, 7-day-retention 'telemetry'
hub and diagnostic settings wired to the existing Log Analytics workspace.

No consumer groups, RBAC role assignments, Capture, or IoT Hub route —
those are later slices per one-area-per-apply cadence.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify working tree is clean**

```bash
git status --short
```
Expected: empty (or only untracked files you explicitly left out, like `terraform.tfvars`).

---

## Done criteria (from spec, re-stated)

- `terraform apply` succeeded from a clean plan (Task 4).
- Namespace + hub + diagnostic setting visible in the child subscription with expected config (Task 5).
- `./run.sh plan` reports no drift (Task 4, Step 2).
- Spec + plan + TF committed together in one commit (Task 6).

## Update persistent state after completion

After Task 6 succeeds, update the project-state memory at
`/home/eyal/.claude/projects/-home-eyal-repos-guardian-link/memory/project-state.md`
to add the Event Hubs namespace + telemetry hub + diagnostic setting to the
"applied as of" list, and bump the date stamp. This is the same file MEMORY.md
already references; do not create a new one.
