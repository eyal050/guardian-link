# GuardianLink telemetry-writer Function

Event-Hub-triggered Python Function App that consumes from the
`telemetry` hub and (eventually) writes raw events to Blob + hot rows
to Cosmos.

**Slice α (this commit):** the function body just logs each event to
App Insights to verify the identity-based EH trigger actually fires.
Blob write lands in the next slice; Cosmos in a later one.

The infrastructure (App Service plan, Function App, identity-based EH
connection, `Azure Event Hubs Data Receiver` role grant, FunctionAppLogs
diagnostics, and the dedicated `telemetry-writer` consumer group) is in
`terraform/guardianlink-dev/functions.tf`.

## Why a Function and not a Container App

Architecture decision: the telemetry-writer is a Function App, not a
Container App. The Functions Event Hubs trigger handles partition
assignment and checkpointing in its own internal `AzureWebJobsStorage`,
so the durable writer doesn't reuse the `eh-checkpoints` blob container
that `apps/consumer/` uses — that container exists only to support the
local debug consumer's `BlobCheckpointStore`. Two different consumer-
group strategies, deliberately. See `docs/architecture.md` decision #8.

## Prerequisites

- Azure Functions Core Tools v4 (`func --version` should report `4.x`).
  Install per Microsoft docs: search "install Azure Functions Core Tools".
- Azure CLI logged in against the `guardianlink-dev` subscription:
  `az account show` should return `name: guardianlink-dev`.
- Python 3.10 in the toolchain (`python --version`). The plan is
  configured for 3.10; deploying a wheel built against a different minor
  lands in a runtime that doesn't have it.
- The Terraform stack applied (`func-…-telemetry-writer` must exist).

## Local setup

```bash
cd apps/telemetry-writer
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
python -m pytest                  # should pass before deploying
```

## Deploy

```bash
source .venv/bin/activate
func azure functionapp publish func-guardianlink-dev-weu-telemetry-writer --python
```

`func` packages the source (respecting `.funcignore`) and runs a remote
build on the Linux Consumption host. First publish takes ~2-3 min.

## Verify

1. Run the simulator in a second terminal:
   ```bash
   cd ../simulator && python simulator.py --device sim-01
   ```
2. In App Insights → Logs (allow ~30-60s after first apply for RBAC
   propagation; until then expect 401/403 in `FunctionAppLogs`):
   ```kusto
   traces
   | where timestamp > ago(10m)
   | where cloud_RoleName == "func-guardianlink-dev-weu-telemetry-writer"
   | where message == "event_received"
   | project timestamp,
             device_id   = tostring(customDimensions.device_id),
             event_type  = tostring(customDimensions.event_type),
             offset      = tostring(customDimensions.offset)
   | take 20
   ```
   Expected: one row per simulator message with `event_type` =
   `telemetry` or `crash_suspect` and `device_id` populated.

3. Cross-check checkpoint isolation: the writer's checkpoints land in
   the AzureWebJobsStorage account (`stgl*`) under blob container
   `azure-webjobs-eventhub`. The `apps/consumer/` debug consumer's
   checkpoints continue to live under `eh-checkpoints` — they are NOT
   shared. Two separate consumer groups, two separate stores.

## What's NOT in this slice

- Blob write of raw events (next slice).
- Cosmos hot-write (later slice).
- DLQ / poison-message handling beyond default trigger retry.
- Batch cardinality (currently single-event; `cardinality=many` is a
  follow-up perf slice).

## Troubleshooting

- **No `event_received` rows in App Insights.** Check `FunctionAppLogs`
  for trigger startup errors. Common causes: RBAC not yet propagated
  (wait 60s and retry); `EH_TELEMETRY__credential` typo; consumer group
  `telemetry-writer` not actually created on the hub.
- **Connection refused / 401 from EH.** Confirm
  `EH_TELEMETRY__fullyQualifiedNamespace` matches
  `<namespace>.servicebus.windows.net` (no `https://`, no trailing slash).
- **Function App boots but trigger never fires.** The host needs read
  access to the EH namespace's metadata too in some scenarios. If
  symptoms point that way, broaden the role scope from the hub to the
  namespace temporarily and narrow back once it works.
