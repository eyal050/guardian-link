# Observability workbook — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a single Application Insights Workbook to `appi-guardianlink-dev-weu` with four panels (throughput, event_type distribution, producer/consumer totals, partition distribution) plus a time-range parameter, with the four queries living as separate `.kql` files for review-friendliness.

**Architecture:** New `dashboards/queries/*.kql` source-of-truth files + a new `terraform/guardianlink-dev/dashboards.tf` that builds the workbook payload via `jsonencode` over an HCL structure (queries pulled in via `file()`). One `azurerm_application_insights_workbook` resource. No tests (all artifacts are TF-managed JSON or Kusto strings); validation is `terraform plan` + manual portal check. Spec: `docs/superpowers/specs/2026-04-25-observability-workbook-slice-design.md`.

**Tech Stack:** Terraform (azurerm 4.69), Kusto (KQL) embedded as static strings.

**Pre-existing infra this depends on (commit `eb0cf71`):**
- `azurerm_application_insights.main` exists in the stack (`appi-guardianlink-dev-weu`).
- App Insights `traces` table contains overnight `message_sent` + `message_received` log records with flat `customDimensions` (`event_type`, `partition_id`, `device_id`).

**Testing approach:** No unit tests. Validation: `terraform fmt`, `./run.sh validate`, `./run.sh plan` showing exactly 1 add, then apply, then a portal-side check that the workbook renders all four panels against overnight data.

**Stack-specific mechanics** (carried over from prior slices):
- `./run.sh <cmd>` wraps `terraform init` with backend config; use it for every `plan` / `apply` / `validate` / `fmt`.
- Every workload resource MUST set `provider = azurerm.workload`.
- `azurerm 4.x` deprecation warnings on `metric` blocks are pre-existing and unrelated.

---

## File Structure

- **Create:**
  - `dashboards/queries/throughput.kql`
  - `dashboards/queries/event_type_distribution.kql`
  - `dashboards/queries/producer_consumer_totals.kql`
  - `dashboards/queries/partition_distribution.kql`
  - `dashboards/README.md`
  - `terraform/guardianlink-dev/dashboards.tf`
- **Modify:** none.

---

## Task 1: Author the four `.kql` source files

**Files:**
- Create: `dashboards/queries/throughput.kql`
- Create: `dashboards/queries/event_type_distribution.kql`
- Create: `dashboards/queries/producer_consumer_totals.kql`
- Create: `dashboards/queries/partition_distribution.kql`

The `{TimeRange}` token in each file is workbook parameter syntax (NOT Terraform interpolation) — it's substituted at render time inside Azure based on the parameter the workbook defines in Task 3. Leave it literal.

- [ ] **Step 1: Create `dashboards/queries/throughput.kql`**

```kusto
traces
| where timestamp {TimeRange}
| where message in ("message_sent", "message_received")
| summarize count() by bin(timestamp, 1m), message
| render timechart
```

- [ ] **Step 2: Create `dashboards/queries/event_type_distribution.kql`**

```kusto
traces
| where timestamp {TimeRange}
| where message == "message_sent"
| summarize count() by tostring(customDimensions.event_type)
```

- [ ] **Step 3: Create `dashboards/queries/producer_consumer_totals.kql`**

```kusto
traces
| where timestamp {TimeRange}
| where message in ("message_sent", "message_received")
| summarize count() by message
```

- [ ] **Step 4: Create `dashboards/queries/partition_distribution.kql`**

```kusto
traces
| where timestamp {TimeRange}
| where message == "message_received"
| summarize count() by tostring(customDimensions.partition_id)
| order by tostring(customDimensions.partition_id) asc
```

- [ ] **Step 5: Verify files exist and have non-empty content**

```bash
find dashboards/queries -type f -name '*.kql' | sort
wc -l dashboards/queries/*.kql
```
Expected: 4 files; each between 4 and 7 lines.

---

## Task 2: Author `dashboards/README.md`

**Files:**
- Create: `dashboards/README.md`

- [ ] **Step 1: Write the README**

```markdown
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
```

- [ ] **Step 2: Verify**

```bash
wc -l dashboards/README.md
```
Expected: 50-70 lines.

---

## Task 3: Add the workbook resource in Terraform

**Files:**
- Create: `terraform/guardianlink-dev/dashboards.tf`

- [ ] **Step 1: Create `dashboards.tf`**

```hcl
# Application Insights Workbook visualizing the telemetry pipeline.
#
# Queries are sourced from dashboards/queries/*.kql so they can be
# reviewed as standalone Kusto. The workbook structure itself lives
# here as HCL and is serialized via jsonencode -- no separate
# workbook.json artifact in the repo, no JSON-string-escaping
# headaches.
#
# The {TimeRange} tokens inside the .kql files are workbook parameter
# syntax (substituted by Azure at render time based on the user's
# selection), NOT Terraform interpolation. Treat them as literal
# strings.

locals {
  workbook_queries = {
    throughput               = file("${path.module}/../../dashboards/queries/throughput.kql")
    event_type_distribution  = file("${path.module}/../../dashboards/queries/event_type_distribution.kql")
    producer_consumer_totals = file("${path.module}/../../dashboards/queries/producer_consumer_totals.kql")
    partition_distribution   = file("${path.module}/../../dashboards/queries/partition_distribution.kql")
  }

  workbook_data = jsonencode({
    version = "Notebook/1.0"
    items = [
      # 1. Markdown header
      {
        type = 1
        name = "header"
        content = {
          json = "## GuardianLink — telemetry pipeline\n\nThroughput, event-type mix, end-to-end parity, and partition distribution for the device-ingest path. Use the time-range picker below to zoom in or out; all panels react."
        }
      },
      # 2. Time-range parameter
      {
        type = 9
        name = "time-range"
        content = {
          version = "KqlParameterItem/1.0"
          parameters = [
            {
              id          = "11111111-1111-1111-1111-111111111111"
              version     = "KqlParameterItem/1.0"
              name        = "TimeRange"
              type        = 4
              isRequired  = true
              value = {
                durationMs = 86400000
              }
              typeSettings = {
                selectableValues = [
                  { durationMs = 1800000 },     # 30 minutes
                  { durationMs = 3600000 },     # 1 hour
                  { durationMs = 14400000 },    # 4 hours
                  { durationMs = 86400000 },    # 24 hours
                  { durationMs = 604800000 },   # 7 days
                ]
              }
            }
          ]
        }
      },
      # 3. Throughput timechart
      {
        type = 3
        name = "throughput"
        content = {
          version       = "KqlItem/1.0"
          query         = local.workbook_queries.throughput
          size          = 0
          title         = "Throughput (messages/min)"
          timeContext   = { durationMs = 86400000 }
          queryType     = 0
          resourceType  = "microsoft.insights/components"
          visualization = "timechart"
        }
      },
      # 4. Event-type pie
      {
        type = 3
        name = "event-type-distribution"
        content = {
          version       = "KqlItem/1.0"
          query         = local.workbook_queries.event_type_distribution
          size          = 0
          title         = "Distribution by event_type (sent)"
          timeContext   = { durationMs = 86400000 }
          queryType     = 0
          resourceType  = "microsoft.insights/components"
          visualization = "piechart"
        }
      },
      # 5. Producer/Consumer tiles
      {
        type = 3
        name = "producer-consumer-totals"
        content = {
          version       = "KqlItem/1.0"
          query         = local.workbook_queries.producer_consumer_totals
          size          = 0
          title         = "Producer vs Consumer (totals)"
          timeContext   = { durationMs = 86400000 }
          queryType     = 0
          resourceType  = "microsoft.insights/components"
          visualization = "tiles"
        }
      },
      # 6. Partition bar chart
      {
        type = 3
        name = "partition-distribution"
        content = {
          version       = "KqlItem/1.0"
          query         = local.workbook_queries.partition_distribution
          size          = 0
          title         = "Messages received by partition"
          timeContext   = { durationMs = 86400000 }
          queryType     = 0
          resourceType  = "microsoft.insights/components"
          visualization = "barchart"
        }
      },
    ]
    "$schema" = "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"
  })
}

resource "azurerm_application_insights_workbook" "telemetry" {
  provider = azurerm.workload

  # Azure requires Workbook resource names to be a GUID. Hardcoded to
  # keep state stable; random_uuid() would track in state and a
  # destroy-recreate cycle would surface as scary diff churn.
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

- [ ] **Step 2: Format and validate**

From `terraform/guardianlink-dev/`:
```bash
terraform fmt
./run.sh validate
```
Expected: `fmt` silent or normalizes whitespace; `validate` prints `Success! The configuration is valid` (the pre-existing `metric` deprecation warnings are unrelated).

If validate complains about an unsupported argument on `azurerm_application_insights_workbook`, the provider version may have shifted from the pinned `~> 4.69.0`; stop and investigate rather than guessing.

- [ ] **Step 3: Plan and inspect**

```bash
./run.sh plan
```
Expected: `Plan: 1 to add, 0 to change, 0 to destroy.` The single addition is `azurerm_application_insights_workbook.telemetry` with:
- `name = "5b2d4f70-1a2c-4e8f-9c1b-7e3a8d6f9a01"`
- `display_name = "GuardianLink — telemetry pipeline"`
- `category = "workbook"`
- `source_id` referencing `azurerm_application_insights.main`
- `data_json` is a long JSON string — skim it for the four `query` keys with the actual Kusto pulled from the `.kql` files. If `query` shows literal `${...}` placeholders or the `.kql` content is missing, the `file()` interpolation didn't resolve — fix path and re-plan.

If plan reports any change beyond the single add, STOP and investigate.

---

## Task 4: Apply

**Files:** none.

- [ ] **Step 1: Apply**

```bash
./run.sh apply -auto-approve
```
Expected: `Apply complete! Resources: 1 added, 0 changed, 0 destroyed.` Workbook resources create in seconds.

- [ ] **Step 2: Confirm no drift**

```bash
./run.sh plan
```
Expected: `No changes. Your infrastructure matches the configuration.`

If drift is reported, record exactly what `data_json` field changed and stop — usually means the HCL serialization isn't byte-identical between plans (rare with `jsonencode` but possible if an interpolated `.kql` file has a trailing newline difference).

---

## Task 5: Verify the workbook in Azure

**Files:** none.

- [ ] **Step 1: Confirm via CLI**

```bash
az resource list -g rg-guardianlink-dev --resource-type "microsoft.insights/workbooks" \
  --query "[].{name:name, displayName:tags.\"hidden-title\"}" -o table
```
Expected: one row.
- `name` = `5b2d4f70-1a2c-4e8f-9c1b-7e3a8d6f9a01`
- `displayName` (from the `hidden-title` tag) = `GuardianLink — telemetry pipeline`

If the table is empty, the workbook didn't land — re-check apply output. If the apply succeeded but the resource isn't visible, check that `az account show --query name -o tsv` returns `guardianlink-dev`.

- [ ] **Step 2: Open in the portal and validate panels**

Manual step. Portal -> `appi-guardianlink-dev-weu` -> **Workbooks** -> "My workbooks" tab -> open **GuardianLink — telemetry pipeline**.

Set the time-range picker to **Last 24 hours**.

Expected:
- **Throughput** chart shows two series (`message_sent` ~204/hr line over the overnight run, `message_received` only during the brief E2E test window).
- **Distribution by event_type** pie shows `telemetry` dominant, `crash_suspect` smaller slice.
- **Producer vs Consumer totals** shows `message_sent` close to ~1840 (overnight count); `message_received` much smaller (consumer was only running briefly).
- **Per-partition distribution** bar chart shows one tall bar (the partition hashed by `sim-01`) and three empties.

If any panel says "no results found" at the 24-hour range, switch to "Last 7 days" — App Insights ingestion has up to a few-minute lag and the overnight window may not be aligned to the picker's bucket. If still empty, the query's KQL is likely broken; export the panel's "Edit" view and inspect.

- [ ] **Step 3: Confirm parameter wiring**

Change the time-range picker to **Last 30 minutes**. All four panels should refresh and most likely report low/zero counts (no simulator running). Switch back to **Last 24 hours**; counts return.

Empty results at 30m are correct, not a failure.

---

## Task 6: Commit

**Files staged:**
- `docs/superpowers/specs/2026-04-25-observability-workbook-slice-design.md`
- `docs/superpowers/plans/2026-04-25-observability-workbook-slice.md`
- `dashboards/queries/throughput.kql`
- `dashboards/queries/event_type_distribution.kql`
- `dashboards/queries/producer_consumer_totals.kql`
- `dashboards/queries/partition_distribution.kql`
- `dashboards/README.md`
- `terraform/guardianlink-dev/dashboards.tf`

- [ ] **Step 1: Stage exact files**

From repo root:
```bash
git add \
  docs/superpowers/specs/2026-04-25-observability-workbook-slice-design.md \
  docs/superpowers/plans/2026-04-25-observability-workbook-slice.md \
  dashboards/queries/throughput.kql \
  dashboards/queries/event_type_distribution.kql \
  dashboards/queries/producer_consumer_totals.kql \
  dashboards/queries/partition_distribution.kql \
  dashboards/README.md \
  terraform/guardianlink-dev/dashboards.tf
```

- [ ] **Step 2: Verify staged set**

```bash
git status --short
```
Expected: exactly 8 `A ` lines for the files above. Nothing else staged.

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
add Application Insights workbook visualizing the telemetry pipeline

dashboards/queries/*.kql + terraform/guardianlink-dev/dashboards.tf
deploy a single azurerm_application_insights_workbook with four panels:
- throughput (sent + received series, 1-min bins)
- event_type distribution (telemetry vs crash_suspect)
- producer vs consumer totals (parity check)
- per-partition distribution

Queries live as standalone .kql files for review-friendliness; the
workbook structure is HCL serialized via jsonencode (no separate
workbook.json, no JSON escaping headaches). The workbook attaches to
the existing appi-guardianlink-dev-weu component and exposes a
time-range picker (default 24h).

Out of scope: alerts + action group (separate slice once more services
exist), classifier/notifier/cost tiles (services don't exist yet),
auto-sync of portal edits back to TF (manual reconcile per README).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify clean tree**

```bash
git status --short
```
Expected: empty.

---

## Done criteria

- `./run.sh plan` after apply reports `No changes`.
- `az resource list ... microsoft.insights/workbooks` shows the workbook.
- Portal renders all 4 panels at 24-hour scope; time-range picker changes the data.
- Spec + plan + 4 `.kql` files + README + `dashboards.tf` committed in one commit.

## Update persistent state after completion

After Task 6 succeeds, update `/home/eyal/.claude/projects/-home-eyal-repos-guardian-link/memory/project-state.md`:
- Add a bullet for the deployed workbook (resource name GUID, display name).
- Bump the commit SHA.
- Refresh the "next slice candidates" list to remove "Workbook" and add "Alerts + action group" as the natural follow-on.
