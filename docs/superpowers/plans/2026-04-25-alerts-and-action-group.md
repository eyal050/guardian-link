# Alerts + action group — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy one `azurerm_monitor_action_group` (single email receiver to `eyal050@gmail.com`) plus three `azurerm_monitor_scheduled_query_rules_alert_v2` rules — `no_telemetry` and `crash_spike` over App Insights `traces`, `no_iot_connections` over LAW `AzureDiagnostics` for IoT Hub `Connections` — with the three KQL queries living as separate `.kql` files for review-friendliness.

**Architecture:** New `alerts/queries/*.kql` source-of-truth files + a new `terraform/guardianlink-dev/alerts.tf` that wires those queries into the v2 alert resource via `file()`. Same pattern as the prior workbook slice. No tests (all artifacts are TF-managed); validation is `terraform plan` + Azure CLI confirmation + a manual stop-the-sim email check. Spec: `docs/superpowers/specs/2026-04-25-alerts-and-action-group-design.md`.

**Tech Stack:** Terraform (azurerm 4.69), Kusto (KQL).

**Pre-existing infra this depends on (commit `8e54f00`):**
- `azurerm_application_insights.main` and `azurerm_log_analytics_workspace.main` exist in the stack.
- IoT Hub diagnostic setting routing `Connections` to LAW (`AzureDiagnostics` legacy table mode — the diagnostic setting does NOT set `log_analytics_destination_type = "Dedicated"`).
- `local.name_prefix` and `local.tags` exist in `terraform/guardianlink-dev/locals.tf`.
- `var.primary_location` exists in `variables.tf`.

**Testing approach:** No unit tests. Validation: `terraform fmt`, `./run.sh validate`, `./run.sh plan` showing exactly 4 adds, then apply, then `az monitor` CLI confirmation, then a portal-side / email check by stopping the simulator.

**Stack-specific mechanics** (carried over from prior slices):
- `./run.sh <cmd>` wraps `terraform init` with backend config; use it for every `plan` / `apply` / `validate` / `fmt`.
- Every workload resource MUST set `provider = azurerm.workload`.
- `azurerm 4.x` deprecation warnings on `metric` blocks are pre-existing and unrelated.
- The `az resource list` core CLI is broken on this machine (module load error). Use `az monitor scheduled-query list` and `az monitor action-group show` for verification — they go through the `monitor` extension, which works.

---

## File Structure

- **Create:**
  - `alerts/queries/no_telemetry.kql`
  - `alerts/queries/crash_spike.kql`
  - `alerts/queries/no_iot_connections.kql`
  - `alerts/README.md`
  - `terraform/guardianlink-dev/alerts.tf`
- **Modify:** none.

---

## Task 1: Author the three `.kql` source files

**Files:**
- Create: `alerts/queries/no_telemetry.kql`
- Create: `alerts/queries/crash_spike.kql`
- Create: `alerts/queries/no_iot_connections.kql`

The window + cadence live on the alert resource (`window_duration`, `evaluation_frequency`), NOT in the KQL — `window_duration` constrains the lookback automatically. Each KQL must `summarize <column> = count()` because the v2 `criteria` block references that column via `metric_measure_column`.

- [ ] **Step 1: Create `alerts/queries/no_telemetry.kql`**

```kusto
traces
| where message == "message_sent"
| summarize sent = count()
```

- [ ] **Step 2: Create `alerts/queries/crash_spike.kql`**

```kusto
traces
| where message == "message_sent"
| where tostring(customDimensions.event_type) == "crash_suspect"
| summarize crashes = count()
```

- [ ] **Step 3: Create `alerts/queries/no_iot_connections.kql`**

```kusto
AzureDiagnostics
| where ResourceType == "IOTHUBS"
| where Category == "Connections"
| where ResultType == "Success"
| summarize connects = count()
```

- [ ] **Step 4: Verify files exist and have non-empty content**

```bash
find alerts/queries -type f -name '*.kql' | sort
wc -l alerts/queries/*.kql
```
Expected: 3 files; each between 3 and 6 lines.

---

## Task 2: Author `alerts/README.md`

**Files:**
- Create: `alerts/README.md`

- [ ] **Step 1: Write the README**

```markdown
# GuardianLink alerts

Three Azure Monitor scheduled-query alert rules + one action group, all
deployed to `rg-guardianlink-dev`. Notifications go by email to
`eyal050@gmail.com`.

Queries live as `.kql` files under `queries/`. The alert rules
themselves are defined in Terraform (`terraform/guardianlink-dev/alerts.tf`)
and pull each query in via `file()`.

## Action group

`ag-guardianlink-dev-weu` (short name `glink-dev`). One `email_receiver`,
shared by all three rules. Adding PagerDuty / Slack / Teams later means
adding a receiver block here without touching the alert rules.

## Rules

### no_telemetry (severity 3 — warning)
Source: `queries/no_telemetry.kql`. Scope: App Insights
`appi-guardianlink-dev-weu`. Window 10 min, eval every 5 min. Fires
when `count(message == "message_sent") == 0`. Will fire any time the
local simulator is stopped — that's the demo, not a bug.

### crash_spike (severity 2 — error)
Source: `queries/crash_spike.kql`. Scope: App Insights. Window 10 min,
eval every 5 min. Fires when `count(event_type == "crash_suspect") > 10`.
Sim's nominal rate is ~5/10min, so the threshold is 2x baseline. To
demo: temporarily lower the simulator's `crash_suspect` interval and
wait one eval cycle.

### no_iot_connections (severity 2 — error)
Source: `queries/no_iot_connections.kql`. Scope: LAW
`log-guardianlink-dev-weu`. Window 30 min, eval every 15 min. Fires
when zero successful Connections rows in `AzureDiagnostics` over the
window. IoT Hub Connections are emit-on-event (not periodic) so the
30 min window covers normal heartbeat cadence.

This rule depends on the legacy `AzureDiagnostics` schema. If the
IoT Hub diagnostic setting is ever flipped to
`log_analytics_destination_type = "Dedicated"`, the data moves to
resource-specific tables and this query breaks. The fix is to
re-target whatever table holds the migrated logs, in the same slice.

## Editing

Source-of-truth is the `.kql` files plus `alerts.tf`. To change a
threshold, edit `alerts.tf` (the threshold lives in the HCL `criteria`
block, NOT in the KQL — see "v2 quirks" below). To change the query
itself, edit the `.kql` and run `./run.sh apply` from
`terraform/guardianlink-dev/`.

## v2 quirks to know

- Threshold expressed in two places: the KQL's `summarize <col> = count()`
  and the HCL `criteria` block's `metric_measure_column` / `operator`
  / `threshold`. The KQL alone does NOT define when the alert fires.
- `failing_periods` block is mandatory. `1 of 1` = no dampening.
- `query_time_range_override` should match `window_duration` or the
  query window silently shrinks to the eval frequency.
- `auto_mitigation_enabled = true` so alerts auto-resolve when the
  condition clears.

## Pitfall: portal edits

If you click "Edit" in the portal and save, those changes do NOT flow
back to Terraform. Next `terraform apply` will silently revert them.
If you tune in the portal, reconcile back into the `.kql` and the
`alerts.tf` first, then apply.
```

- [ ] **Step 2: Verify**

```bash
wc -l alerts/README.md
```
Expected: 55-75 lines.

---

## Task 3: Add the action group + three alert rules in Terraform

**Files:**
- Create: `terraform/guardianlink-dev/alerts.tf`

- [ ] **Step 1: Create `alerts.tf`**

```hcl
# Azure Monitor scheduled-query alerts on the producer side.
#
# Three rules, one action group with a single email receiver to
# eyal050@gmail.com. The KQL for each rule is sourced from
# alerts/queries/*.kql so the queries can be reviewed as standalone
# Kusto.
#
# Two rules scope to App Insights (`message_sent` rows from the
# simulator), one scopes to LAW (`AzureDiagnostics` -> IoT Hub
# Connections category). Mixing scope types in a single resource is
# not supported by azurerm_monitor_scheduled_query_rules_alert_v2 --
# that's why we have three resources, not one with three criteria
# blocks.
#
# v2 criteria-block quirks (worth re-reading before editing):
#   1. Threshold lives in HCL (operator / metric_measure_column /
#      threshold), NOT in the KQL. The KQL just exposes the count
#      column. Changing the KQL alone will NOT change firing behavior.
#   2. failing_periods is mandatory. 1 of 1 = no dampening.
#   3. query_time_range_override should match window_duration or the
#      query lookback silently shrinks to the eval cadence.

locals {
  alert_queries = {
    no_telemetry       = file("${path.module}/../../alerts/queries/no_telemetry.kql")
    crash_spike        = file("${path.module}/../../alerts/queries/crash_spike.kql")
    no_iot_connections = file("${path.module}/../../alerts/queries/no_iot_connections.kql")
  }
}

resource "azurerm_monitor_action_group" "email" {
  provider = azurerm.workload

  name                = "ag-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "glink-dev" # 12-char max, shows in email subject

  email_receiver {
    name          = "eyal-primary"
    email_address = "eyal050@gmail.com"
  }

  tags = local.tags
}

# ---------- Rule 1: no telemetry from the simulator ----------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "no_telemetry" {
  provider = azurerm.workload

  name                = "alert-no-telemetry-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.primary_location

  scopes                  = [azurerm_application_insights.main.id]
  severity                = 3
  evaluation_frequency    = "PT5M"
  window_duration         = "PT10M"
  description             = "No message_sent events in the last 10 minutes from the simulator."
  enabled                 = true
  auto_mitigation_enabled = true

  criteria {
    query                   = local.alert_queries.no_telemetry
    time_aggregation_method = "Total"
    metric_measure_column   = "sent"
    threshold               = 0
    operator                = "Equal"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  query_time_range_override = "PT10M"

  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }

  tags = local.tags
}

# ---------- Rule 2: crash_suspect rate spike ----------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "crash_spike" {
  provider = azurerm.workload

  name                = "alert-crash-spike-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.primary_location

  scopes                  = [azurerm_application_insights.main.id]
  severity                = 2
  evaluation_frequency    = "PT5M"
  window_duration         = "PT10M"
  description             = "More than 10 crash_suspect events in the last 10 minutes (baseline ~5)."
  enabled                 = true
  auto_mitigation_enabled = true

  criteria {
    query                   = local.alert_queries.crash_spike
    time_aggregation_method = "Total"
    metric_measure_column   = "crashes"
    threshold               = 10
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  query_time_range_override = "PT10M"

  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }

  tags = local.tags
}

# ---------- Rule 3: no IoT Hub successful Connections ----------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "no_iot_connections" {
  provider = azurerm.workload

  name                = "alert-no-iot-connections-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.primary_location

  scopes                  = [azurerm_log_analytics_workspace.main.id]
  severity                = 2
  evaluation_frequency    = "PT15M"
  window_duration         = "PT30M"
  description             = "No successful IoT Hub Connections rows in AzureDiagnostics over the last 30 minutes."
  enabled                 = true
  auto_mitigation_enabled = true

  criteria {
    query                   = local.alert_queries.no_iot_connections
    time_aggregation_method = "Total"
    metric_measure_column   = "connects"
    threshold               = 0
    operator                = "Equal"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  query_time_range_override = "PT30M"

  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }

  tags = local.tags
}
```

- [ ] **Step 2: Format and validate**

From `terraform/guardianlink-dev/`:
```bash
terraform fmt
./run.sh validate
```
Expected: `fmt` silent or normalizes whitespace; `validate` prints `Success! The configuration is valid` (the pre-existing `metric` deprecation warnings are unrelated).

If validate complains about an unsupported argument on `azurerm_monitor_scheduled_query_rules_alert_v2` (e.g., an arg renamed since 4.69 was pinned), STOP and check the provider's registry doc page rather than guessing — the v2 resource has had several rename churns. Likely candidates if anything is wrong: `auto_mitigation_enabled` vs `auto_mitigation`, `query_time_range_override` formatting.

If validate complains about the action group's `short_name` being too long, it's capped at 12 chars by Azure — `glink-dev` is 9 chars and fits.

- [ ] **Step 3: Plan and inspect**

```bash
./run.sh plan
```
Expected: `Plan: 4 to add, 0 to change, 0 to destroy.` The four additions are:
1. `azurerm_monitor_action_group.email` with one `email_receiver` for `eyal050@gmail.com`.
2. `azurerm_monitor_scheduled_query_rules_alert_v2.no_telemetry` — scope = AppInsights, severity 3, threshold 0 / Equal, window 10m / eval 5m.
3. `azurerm_monitor_scheduled_query_rules_alert_v2.crash_spike` — scope = AppInsights, severity 2, threshold 10 / GreaterThan, window 10m / eval 5m.
4. `azurerm_monitor_scheduled_query_rules_alert_v2.no_iot_connections` — scope = LAW workspace ID, severity 2, threshold 0 / Equal, window 30m / eval 15m.

Each alert resource's `criteria.query` field in the plan output should show the actual KQL pulled from the corresponding `.kql` file. If `query` shows literal `${...}` placeholders, the `file()` interpolation didn't resolve — fix the path (`${path.module}/../../alerts/queries/...`).

If plan reports any change beyond the four adds, STOP and investigate.

---

## Task 4: Apply

**Files:** none.

- [ ] **Step 1: Apply**

```bash
./run.sh apply -auto-approve
```
Expected: `Apply complete! Resources: 4 added, 0 changed, 0 destroyed.` Action groups and scheduled-query alerts both create in seconds.

- [ ] **Step 2: Confirm no drift**

```bash
./run.sh plan
```
Expected: `No changes. Your infrastructure matches the configuration.`

If drift is reported, record exactly what field changed and stop. Most likely cause for v2 alert rules is the provider normalizing one of the `criteria` block fields server-side; if so, set the field to whatever the server returned and re-plan.

---

## Task 5: Verify in Azure (CLI + email)

**Files:** none.

- [ ] **Step 1: Confirm via CLI — three alert rules**

```bash
az monitor scheduled-query list -g rg-guardianlink-dev \
  --query "[].{name:name, severity:severity, enabled:enabled, evalFreq:evaluationFrequency, window:windowSize}" \
  -o table
```
Expected: three rows, one per rule, with the severities (3, 2, 2) and frequencies / windows from the spec.

If the table is empty, the apply didn't land — re-check the apply output. If only some rules show, check that `az account show --query name -o tsv` returns `guardianlink-dev`.

- [ ] **Step 2: Confirm via CLI — action group**

```bash
az monitor action-group show -n ag-guardianlink-dev-weu -g rg-guardianlink-dev \
  --query "{name:name, shortName:groupShortName, emailReceivers:emailReceivers[].{name:name, email:emailAddress}}" \
  -o json
```
Expected: a single object with `shortName = "glink-dev"` and one `emailReceivers` entry for `eyal-primary` / `eyal050@gmail.com`.

- [ ] **Step 3: Confirm action wiring on each rule**

```bash
az monitor scheduled-query list -g rg-guardianlink-dev \
  --query "[].{name:name, actionGroups:actions.actionGroups}" \
  -o json
```
Expected: each rule has its `actionGroups` array containing the action-group resource ID ending in `/actionGroups/ag-guardianlink-dev-weu`.

If any rule's `actionGroups` is empty, the alert is wired but won't notify — the `action { action_groups = [...] }` block in `alerts.tf` is wrong.

- [ ] **Step 4: Manual email check (no_telemetry)**

This is a real Azure round-trip — total expected wait ~15 minutes from sim-stop to email arrival (5 min eval cadence + LAW ingestion latency + email send).

1. If the simulator is currently running, stop it (`Ctrl-C` in `apps/simulator/`). If it isn't running, you're already in the trigger condition.
2. Wait 15 minutes.
3. Check `eyal050@gmail.com` for an Azure Monitor alert email with subject containing `glink-dev` and body referencing `alert-no-telemetry-guardianlink-dev-weu`.
4. Re-start the simulator.
5. Wait another ~10 minutes.
6. Confirm the alert auto-resolves — check the Azure portal `Monitor -> Alerts` view; the `no_telemetry` alert should move from "New" to "Closed" (auto-mitigation_enabled = true).

Record the alert ID so you have a reference if you want to check the resolved-state later. If no email arrives after 25 minutes:
- Check the Azure portal `Monitor -> Alerts` view for the alert in any state. If the alert exists but no email arrived, the action group is misconfigured (re-check Step 2).
- If the alert doesn't exist at all, the rule isn't firing — likely a KQL or `metric_measure_column` mismatch. Re-check `criteria` block.
- Spam folder check on the email side.

`crash_spike` and `no_iot_connections` are NOT verified manually in this task — they require a sim modification or a 30+ min disconnect window. Defer to ad-hoc testing.

---

## Task 6: Commit + update memory

**Files staged:**
- `docs/superpowers/specs/2026-04-25-alerts-and-action-group-design.md`
- `docs/superpowers/plans/2026-04-25-alerts-and-action-group.md`
- `alerts/queries/no_telemetry.kql`
- `alerts/queries/crash_spike.kql`
- `alerts/queries/no_iot_connections.kql`
- `alerts/README.md`
- `terraform/guardianlink-dev/alerts.tf`

- [ ] **Step 1: Stage exact files**

From repo root:
```bash
git add \
  docs/superpowers/specs/2026-04-25-alerts-and-action-group-design.md \
  docs/superpowers/plans/2026-04-25-alerts-and-action-group.md \
  alerts/queries/no_telemetry.kql \
  alerts/queries/crash_spike.kql \
  alerts/queries/no_iot_connections.kql \
  alerts/README.md \
  terraform/guardianlink-dev/alerts.tf
```

- [ ] **Step 2: Verify staged set**

```bash
git status --short
```
Expected: exactly 7 `A ` lines for the files above. Nothing else staged.

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
add producer-side alerts + action group

alerts/queries/*.kql + terraform/guardianlink-dev/alerts.tf deploy one
azurerm_monitor_action_group (email receiver eyal050@gmail.com) plus
three azurerm_monitor_scheduled_query_rules_alert_v2 rules:
- no_telemetry (sev 3, AppInsights, fires on count(message_sent)==0
  over 10m, eval 5m -- expected to fire each session when sim stops)
- crash_spike (sev 2, AppInsights, fires on count(crash_suspect)>10
  over 10m, eval 5m -- 2x baseline)
- no_iot_connections (sev 2, LAW AzureDiagnostics, fires on zero
  successful IoT Hub Connections rows over 30m, eval 15m)

Same source-of-truth pattern as the workbook slice -- KQL lives as
standalone .kql files, the v2 alert resource pulls each in via file().

Out of scope: consumer-lag alerts (no durable consumer yet), webhook
/ PagerDuty / Slack receivers (no real downstream), per-severity
action groups, dedicated-table migration for IoT Hub diagnostics
(would break the no_iot_connections KQL).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify clean tree**

```bash
git status --short
```
Expected: empty.

- [ ] **Step 5: Update persistent state**

Update `/home/eyal/.claude/projects/-home-eyal-repos-guardian-link/memory/project-state.md`:
- Add a bullet for the action group (`ag-guardianlink-dev-weu`) and the three alert rules with their severities, scopes, windows, thresholds.
- Bump the commit SHA to the one produced by Step 3 (`git rev-parse --short HEAD`).
- Refresh the "next slice candidates" list — remove "Alerts + action group", and the natural next candidate becomes either porting the consumer to a Container App (which then unlocks consumer-lag alerts as a follow-on) or the Storage + telemetry-writer Function direction.

---

## Done criteria

- `./run.sh plan` after apply reports `No changes`.
- `az monitor scheduled-query list` shows three rules with the agreed severities + windows.
- `az monitor action-group show` shows one email receiver for `eyal050@gmail.com`.
- Manual email-check passes: stop the sim, wait ~15 min, email arrives; restart, alert auto-resolves.
- Spec + plan + 3 `.kql` files + README + `alerts.tf` committed in one commit.
- `project-state.md` updated.
