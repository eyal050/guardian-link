# Alerts + action group — design

**Date:** 2026-04-25
**Location:** new `alerts/queries/*.kql` + `alerts/README.md` + new `terraform/guardianlink-dev/alerts.tf`
**Slice scope:** one `azurerm_monitor_action_group` (single email receiver) + three `azurerm_monitor_scheduled_query_rules_alert_v2` rules (two over App Insights `traces`, one over LAW `AzureDiagnostics` for IoT Hub `Connections`). Producer-side only — alerts on what we *can* observe with the simulator and IoT Hub diagnostic stream as they exist today. No durable consumer means no consumer-lag alert in this slice.

## Purpose

Close the loop on the observability layer: the workbook lets a human notice a problem; alerts let the platform notice it without a human watching. This slice exercises the modern v2 scheduled-query alert resource and proves out the action-group → email path so a follow-on slice (consumer-lag alerts after the consumer is ported to a Container App / Function) drops in trivially.

There is also an interview-prep angle: `azurerm_monitor_scheduled_query_rules_alert_v2` is the resource a real prod platform uses, and the v2 criteria block has enough quirks (KQL-and-HCL-both-express-the-threshold, mandatory `failing_periods`, `query_time_range_override`) that having shipped one is the difference between "I've used Azure Monitor" and "I've actually deployed alerts in Terraform."

## Context

Current state (commit `8e54f00` on `main`): full ingest + local consumer pipeline, App Insights `appi-guardianlink-dev-weu` collecting `traces` from `apps/simulator` (`message_sent`) and `apps/consumer` (`message_received`), App Insights Workbook deployed visualizing those flows. IoT Hub `iot-guardianlink-dev-weu` has a diagnostic setting routing `Connections`, `DeviceTelemetry`, `Routes`, `DeviceIdentityOperations` + `AllMetrics` to LAW `log-guardianlink-dev-weu`. The diagnostic setting does NOT set `log_analytics_destination_type = "Dedicated"`, so logs land in the legacy wide `AzureDiagnostics` table (not resource-specific tables).

User's notification preferences are already on file: budget alerts go to `eyal050@gmail.com`. Same address for these alerts.

Sim's nominal output rates (relevant to threshold tuning):
- `message_sent` with `event_type = "telemetry"`: ~1 every 20s = ~30 in 10 min.
- `message_sent` with `event_type = "crash_suspect"`: ~1 every 120s = ~5 in 10 min.

## File layout

```
alerts/
  README.md                       # describes each rule + KQL + how alerts route
  queries/
    no_telemetry.kql              # count(message_sent) -- fires on 0
    crash_spike.kql               # count(crash_suspect) -- fires on >10
    no_iot_connections.kql        # count(IOTHUBS Connections Success) -- fires on 0

terraform/guardianlink-dev/
  alerts.tf                       # action group + 3 alert rules
```

No `alerts/alerts.json`. Same pattern as the workbook slice — KQL stays as standalone `.kql` files (reviewable as Kusto), the Terraform resource pulls each query in via `file()` and embeds it via the resource's `criteria.query` argument. No JSON encoding because alert rules don't take a JSON payload, just HCL fields.

## Terraform resources

In `terraform/guardianlink-dev/alerts.tf`:

```hcl
locals {
  alert_queries = {
    no_telemetry        = file("${path.module}/../../alerts/queries/no_telemetry.kql")
    crash_spike         = file("${path.module}/../../alerts/queries/crash_spike.kql")
    no_iot_connections  = file("${path.module}/../../alerts/queries/no_iot_connections.kql")
  }
}

resource "azurerm_monitor_action_group" "email" {
  provider = azurerm.workload

  name                = "ag-${local.name_prefix}"   # ag-guardianlink-dev-weu
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "glink-dev"                  # 12 char max

  email_receiver {
    name          = "eyal-primary"
    email_address = "eyal050@gmail.com"
  }

  tags = local.tags
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "no_telemetry" {
  provider = azurerm.workload

  name                = "alert-no-telemetry-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.primary_location

  scopes               = [azurerm_application_insights.main.id]
  severity             = 3
  evaluation_frequency = "PT5M"
  window_duration      = "PT10M"
  description          = "Sim has not produced any message_sent events in the last 10 minutes."
  enabled              = true
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

# crash_spike + no_iot_connections follow the same shape;
# crash_spike scope = AppInsights, threshold = 10, operator = "GreaterThan",
#   metric_measure_column = "crashes", severity = 2;
# no_iot_connections scope = LAW workspace ID, window = "PT30M",
#   evaluation_frequency = "PT15M", metric_measure_column = "connects",
#   threshold = 0, operator = "Equal", severity = 2.
```

The full bodies of all three rules go in the implementation plan; the spec just pins the shape.

### Severity rationale

- **Sev 3 (warning) — no_telemetry:** expected to fire any time the user stops the simulator at end of session. Should not look "critical" in the inbox.
- **Sev 2 (error) — crash_spike, no_iot_connections:** these signal an actual abnormal condition (genuine crash burst, or IoT Hub side connectivity problem). Sev 1 reserved for production-grade hard outages, which this dev environment doesn't have.

For a single recipient with one email channel the practical difference between sev 2 and sev 3 is cosmetic (subject-line prefix), but tagging severity correctly is interview-defensible behavior.

## KQL queries

The window + cadence live on the alert resource, NOT in the KQL — `window_duration` constrains the lookback automatically. Queries summarize over the implicit window and produce a single named numeric column referenced by `metric_measure_column`.

**`alerts/queries/no_telemetry.kql`** (App Insights `traces`):
```kusto
traces
| where message == "message_sent"
| summarize sent = count()
```

**`alerts/queries/crash_spike.kql`** (App Insights `traces`):
```kusto
traces
| where message == "message_sent"
| where tostring(customDimensions.event_type) == "crash_suspect"
| summarize crashes = count()
```

**`alerts/queries/no_iot_connections.kql`** (LAW `AzureDiagnostics`):
```kusto
AzureDiagnostics
| where ResourceType == "IOTHUBS"
| where Category == "Connections"
| where ResultType == "Success"
| summarize connects = count()
```

The third query depends on the legacy `AzureDiagnostics` schema. If a future change flips the IoT Hub diagnostic setting to `log_analytics_destination_type = "Dedicated"`, this query breaks (data will be in a resource-specific table like `AHDS...` or `AzureMetrics`). Either keep both formats or switch to dedicated tables in a separate slice.

## Threshold tuning

| Rule | Window | Eval freq | Threshold | Baseline | Why |
| --- | --- | --- | --- | --- | --- |
| no_telemetry | 10 min | 5 min | `sent == 0` | ~30/10min | Zero is unambiguous. Will fire when sim stops. |
| crash_spike | 10 min | 5 min | `crashes > 10` | ~5/10min | 2x baseline + margin. Demoable by halving the sim's `crash_suspect` interval. |
| no_iot_connections | 30 min | 15 min | `connects == 0` | sparse heartbeat | Connections logs are emit-on-event, not periodic. 30 min covers normal heartbeat cadence. |

## v2 criteria-block quirks (worth knowing)

These are the things that bit me on the workbook slice's neighbor problem and would bite again if not pinned in the spec:

1. **Threshold expressed in two places.** The KQL must `summarize <name> = count()` to produce a numeric column, and the HCL `criteria` block re-expresses the comparison with `metric_measure_column`/`operator`/`threshold`. The KQL alone does NOT define when the alert fires.
2. **`failing_periods` is mandatory.** Required block on v2; `1 of 1` = no dampening (fire on first failed eval). For dev/demo, no dampening is the right default.
3. **`query_time_range_override` should match `window_duration`.** Otherwise the resource silently uses the eval frequency as the query window, which is not what the spec says. Set this explicitly on every rule.
4. **`auto_mitigation_enabled = true`** so the alert state clears when the condition resolves. Otherwise the same alert just sits in "fired" forever and you stop noticing it.
5. **Two scope targets.** Rules 1 + 2 scope to the App Insights component ID; rule 3 scopes to the LAW workspace ID. Mixing scope types in a single resource is not supported — that's why we have three resources, not one with three criteria blocks.

## Action group shape

Single `azurerm_monitor_action_group.email` reused by all three rules. One `email_receiver` block. No webhook, no Logic App, no SMS, no Azure App push. If a follow-on slice needs PagerDuty/Slack, it adds a receiver block here without touching the alert rules.

`short_name` is capped at 12 chars by Azure and is what shows in the email subject line / SMS body. `glink-dev` keeps room to disambiguate from a future `glink-prd`.

## Done criteria

- `./run.sh plan` after apply reports `No changes`.
- `az monitor scheduled-query list -g rg-guardianlink-dev` (or equivalent CLI verification) shows three rules.
- `az monitor action-group show -n ag-guardianlink-dev-weu -g rg-guardianlink-dev` shows the single email receiver.
- Manual verification of at least one alert: stop the simulator, wait ~10-15 minutes, confirm an email lands for `no_telemetry`. Re-start the simulator, confirm the alert auto-resolves. (`crash_spike` is harder to trigger without modifying the simulator's crash interval; `no_iot_connections` requires the simulator to actually disconnect, which is fine to verify by stopping the sim and waiting ~30 min.)
- Spec + 3 `.kql` files + `alerts/README.md` + `alerts.tf` committed in one commit.

## Out of scope

- **Consumer-lag alerts.** No durable consumer running 24/7 — would only fire when the laptop consumer is stopped, which is most of the time. Add once the consumer is a Container App / Function App.
- **Webhook receivers / PagerDuty / Slack.** Adds a receiver type without a real downstream. A placeholder URL is the kind of breadcrumb that rots.
- **Per-severity action groups.** Useful only when severities map to different teams / escalation paths. Single recipient = single AG.
- **Alert suppression / quiet hours.** No prod traffic patterns to model.
- **Azure Monitor metric alerts.** v2 scheduled-query covers everything we need from a single resource type. No reason to introduce a second alert mechanism.
- **Switching IoT Hub diagnostics to dedicated tables.** Would break rule 3's KQL (which references `AzureDiagnostics`). If we want dedicated tables, that's its own slice with the alert KQL change as a side effect.
- **Auto-runbook / auto-remediation.** Not real for this project — there is no auto-restart story for the simulator (it's a local laptop process).

## Risks

- **Email noise.** `no_telemetry` will fire every time the simulator is stopped — which is every session. Plan: tolerate it as the demo-the-pipeline cost. If it gets annoying, add a maintenance-window suppression in a follow-on; do not change the threshold (which would defeat the rule's purpose).
- **`AzureDiagnostics` table schema.** Microsoft has been migrating IoT Hub toward dedicated tables. If the legacy schema is ever sunset, rule 3 breaks. Mitigation: the spec calls this out, README repeats it. A future migration is a known maintenance task.
- **Alert evaluation latency.** Scheduled-query alerts have a few-minute end-to-end delay (eval cadence + LAW ingestion + email send). The "10 min window, 5 min eval" combination means the user should expect ~15 min from "I stopped the sim" to "email arrives." This is fine for the demo and is honest about Azure Monitor's actual behavior.
