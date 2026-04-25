# Observability workbook — design

**Date:** 2026-04-25
**Location:** new `dashboards/queries/*.kql` + `dashboards/README.md` + new `terraform/guardianlink-dev/dashboards.tf`
**Slice scope:** one Application Insights Workbook deployed via Terraform, four panels, queries living as separate `.kql` files for review-friendliness.

## Purpose

Make the telemetry pipeline observable in a single click. Today the only way to verify the simulator → IoT Hub → Event Hub → consumer flow is by stitching together CLI queries against IoT Hub metrics, App Insights logs, and the Event Hub portal. A deployed Workbook puts ingestion rate, event-type distribution, producer/consumer parity, and partition distribution in front of a viewer with a time-range picker.

This is the first slice that *exploits* the data accumulated overnight (~1,840 messages in the 9-hour run) rather than producing more of it. Architecture doc explicitly calls for "at least one Azure Workbook"; this satisfies that minimum.

## Context

Current state (commit `eb0cf71`): full ingest + local consumer pipeline, App Insights (`appi-guardianlink-dev-weu`) collecting `traces` from both `apps/simulator` (`message_sent`) and `apps/consumer` (`message_received`). All log records carry flat `customDimensions` (`event_type`, `partition_id`, `device_id`).

Architecture commits (`docs/architecture.md`):
- Single App Insights component for dev (workspace-linked).
- "At least one Azure Workbook" required.
- Custom-event names defined: `message_sent`, `message_received`. Both land in `traces` (the OTel distro doesn't use the `customEvents` table).

## File layout

```
dashboards/
  README.md                        # describes each panel + Kusto + how to edit
  queries/
    throughput.kql                 # producer + consumer rates per minute
    event_type_distribution.kql    # telemetry vs crash_suspect counts
    producer_consumer_totals.kql   # E2E parity check
    partition_distribution.kql     # message_received counts per partition

terraform/guardianlink-dev/
  dashboards.tf                    # locals { workbook = { ... } } + the workbook resource
```

No `dashboards/workbook.json`. Terraform `jsonencode` produces the workbook payload from an HCL structure that pulls the four queries via `file()`. This keeps the queries Kusto-reviewable while letting Terraform handle JSON escaping automatically — no template-string headaches.

## Terraform resource

In `terraform/guardianlink-dev/dashboards.tf`:

```hcl
locals {
  workbook_queries = {
    throughput              = file("${path.module}/../../dashboards/queries/throughput.kql")
    event_type_distribution = file("${path.module}/../../dashboards/queries/event_type_distribution.kql")
    producer_consumer_totals = file("${path.module}/../../dashboards/queries/producer_consumer_totals.kql")
    partition_distribution  = file("${path.module}/../../dashboards/queries/partition_distribution.kql")
  }

  workbook_data = jsonencode({
    version = "Notebook/1.0"
    items = [
      # Markdown header, time-range parameter, then four query panels.
      # Detail in the file structure below.
    ]
    "$schema" = "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"
  })
}

resource "azurerm_application_insights_workbook" "telemetry" {
  provider = azurerm.workload

  name                = "5b2d4f70-1a2c-4e8f-9c1b-7e3a8d6f9a01"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.primary_location

  display_name = "GuardianLink — telemetry pipeline"
  category     = "workbook"
  source_id    = azurerm_application_insights.main.id
  data_json    = local.workbook_data

  tags = local.tags
}
```

GUID for `name` is fixed (the Azure resource name for a Workbook must be a GUID). Hardcoded over `random_uuid()` to keep state stable and avoid the random's destruction footgun. `display_name` is the user-facing label.

## Workbook structure (HCL `items` array)

Six items, in order:

### 1. Markdown header (type 1)

A one-paragraph banner naming the workbook, what it visualizes, and a one-line note that the time-range param applies to all panels. Kept short — interview viewers skip text.

### 2. Time-range parameter (type 9)

Single parameter `TimeRange`, type "Time range picker" (parameter type 4 in workbook JSON), values:
- 30 minutes, 1 hour, 4 hours, 24 hours, 7 days
- default: 24 hours

All query panels reference `{TimeRange}` (workbook syntax — distinct from Terraform's `${...}`) so they recompute on selection change. The 24h default surfaces overnight runs without the viewer having to fiddle.

### 3. Throughput over time (type 3 — Kusto query, line chart)

Source: `dashboards/queries/throughput.kql`

```kusto
traces
| where timestamp {TimeRange}
| where message in ("message_sent", "message_received")
| summarize count() by bin(timestamp, 1m), message
| render timechart
```

Visualization: line chart, x = time, y = count, series = `message` (so producer and consumer overlap and divergence is visible by eye).

### 4. Distribution by event_type (type 3, pie)

Source: `dashboards/queries/event_type_distribution.kql`

```kusto
traces
| where timestamp {TimeRange}
| where message == "message_sent"
| summarize count() by tostring(customDimensions.event_type)
```

Pie chart over the small set of values (`telemetry`, `crash_suspect`). At default rates (telemetry every 20s, crash every 120s), the pie should sit near 6:1 telemetry:crash. Anomalies in the ratio = the simulator misbehaving.

### 5. Producer vs Consumer totals (type 3, two number tiles)

Source: `dashboards/queries/producer_consumer_totals.kql`

```kusto
traces
| where timestamp {TimeRange}
| where message in ("message_sent", "message_received")
| summarize count() by message
```

Visualization: tiles. Two big numbers side-by-side. Visual divergence = consumer was off, or fell behind, or the route broke. With both apps running, they track within a few seconds of each other.

### 6. Per-partition distribution (type 3, bar)

Source: `dashboards/queries/partition_distribution.kql`

```kusto
traces
| where timestamp {TimeRange}
| where message == "message_received"
| summarize count() by tostring(customDimensions.partition_id)
| order by tostring(customDimensions.partition_id) asc
```

Bar chart, x = partition_id (0–3), y = count. With a single `sim-01` device, all messages currently land on one partition — the bar chart visualizes that and primes the "we hash D2C messages by deviceId" interview talking point. Future multi-device runs will populate the other bars.

## `dashboards/README.md`

Short doc, ~50 lines:

- What the workbook is and where to view it (`Portal → appi-guardianlink-dev-weu → Workbooks → My workbooks → "GuardianLink — telemetry pipeline"`).
- A one-line summary of each panel + a code-fenced copy of its Kusto.
- Editing rhythm: change `dashboards/queries/*.kql`, run `terraform apply` from the stack. The workbook updates in place; Azure preserves user-set state (selected time range) across redeploys.
- Pitfall: the Azure portal's "Save" button updates the workbook in-place but doesn't push back to TF. If you edit in the portal, **export the JSON via "Advanced editor → Gallery template" and reconcile manually** before the next `terraform apply` — otherwise the next apply silently reverts your portal edits. Document this clearly.

## Verification after apply

1. **TF plan/apply:** `./run.sh plan` shows exactly 1 resource to add (`azurerm_application_insights_workbook.telemetry`); `apply` creates it; subsequent plan reports no drift.

2. **CLI:**
   ```
   az resource list -g rg-guardianlink-dev --resource-type "microsoft.insights/workbooks" \
     --query "[].{name:name, displayName:tags.\"hidden-title\"}" -o table
   ```
   Expected one row with the GUID name; `display_name` from the Workbook resource maps to a `hidden-title` tag in the response.

3. **Portal:** App Insights → Workbooks → "My workbooks" → "GuardianLink — telemetry pipeline" → opens with all four panels.

4. **Data check:** With overnight data still in retention, set time range to "Last 24 hours" → Throughput chart shows ~204 msgs/hr line; event-type pie ~6:1; producer vs consumer tiles within ~10% of each other (consumer was only running briefly, so it'll be lower); partition bar chart shows one tall bar at p=0 and three empties.

## Risks and notes

- **Workbook resource changes are noisy in plan output.** `data_json` is a giant string; any whitespace or key-ordering change in the HCL re-renders it and TF reports `data_json` modified even when semantically identical. Keep edits intentional; don't reformat for fun.

- **Portal-edit / TF-edit conflict.** As noted in the README, edits made via the portal's edit mode are NOT pulled back into Terraform. The slice picks "TF is the source of truth" — accept that portal edits get clobbered on next `terraform apply`.

- **Workbook resource name = GUID.** Azure rejects friendly names. Hardcoded; deletion + re-create would generate a new portal URL but the `display_name`-based lookup still finds it. If we ever want stable URLs, a `random_uuid` with `lifecycle.ignore_changes` could lock the GUID — out of scope.

- **Cost.** Workbook resources themselves are free. Query execution costs are LAW ingestion (already paid) and column reads (free for queries against AI traces). No incremental cost.

- **Schema drift.** Microsoft updates the workbook schema occasionally. The `$schema` URL is a soft pointer; if Microsoft changes panel types or required fields, an old JSON may stop rendering. Mitigation: pin to known-working shapes; revisit if a panel breaks.

- **Auth model.** Anyone with Reader on the App Insights component (or the resource group) can view the workbook. No further sharing controls in scope.

## Out of scope

- Alerts and action group (separate slice once more services exist).
- Cost tile, classifier latency tiles, notification success — services don't exist yet.
- Workbook templating beyond the time range (e.g., device_id selector).
- Generic "shared workbook gallery" / cross-subscription publishing.
- A pipeline that auto-syncs portal edits back to TF.

## Done criteria

- `./run.sh plan` adds exactly 1 resource (`azurerm_application_insights_workbook.telemetry`); apply succeeds; re-plan reports no drift.
- All 4 `.kql` files exist and contain the queries above.
- `dashboards/README.md` documents each panel.
- Workbook visible in the portal under App Insights, all 4 panels render, time-range picker works, overnight data populates the throughput chart at 24h scope.
- Spec + plan + TF + .kql files committed together.
