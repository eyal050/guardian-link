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
