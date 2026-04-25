# GuardianLink dashboards

One Application Insights Workbook deployed to `appi-guardianlink-dev-weu`,
visualizing the simulator -> IoT Hub -> Event Hub -> consumer pipeline.

Queries live as `.kql` files under `queries/`. The workbook itself is
defined in Terraform (`terraform/guardianlink-dev/dashboards.tf`) and built
from those queries at apply time via `file()` + `jsonencode`.

## How to view

Azure portal -> `appi-guardianlink-dev-weu` -> **Workbooks** ->
"My workbooks" -> **GuardianLink — telemetry pipeline**.

The workbook accepts a time-range parameter at the top (default 24 hours).

## Panels

### Throughput over time
Source: `queries/throughput.kql`. Line chart of `message_sent` +
`message_received` counts in 1-minute bins, two series so producer and
consumer overlap visually. Divergence = consumer lag or route failure.

### Event-type distribution
Source: `queries/event_type_distribution.kql`. Pie chart of
`message_sent` rows by `customDimensions.event_type`. At default
simulator rates (telemetry every 20s, crash every 120s) the ratio sits
near 6:1 telemetry to crash_suspect.

### Producer vs Consumer totals
Source: `queries/producer_consumer_totals.kql`. Two number tiles for
`message_sent` and `message_received` over the time window. Drift
between the two surfaces consumer downtime.

### Per-partition distribution
Source: `queries/partition_distribution.kql`. Bar chart of
`message_received` counts grouped by `customDimensions.partition_id`.
With one device (sim-01), all messages hash to one partition; multiple
bars only appear once additional devices exist.

## Editing

Source-of-truth is the `.kql` files plus `dashboards.tf`. To change a
query: edit the `.kql`, run `./run.sh apply` from
`terraform/guardianlink-dev/`. The workbook updates in place.

## Pitfall: portal edits

If you click "Edit" in the portal and save, those changes do NOT flow
back to Terraform. Next `terraform apply` will silently revert them.
If you tune in the portal, export the JSON via
`Edit -> Advanced editor -> Gallery template`, reconcile back into
this repo, and only then apply.
