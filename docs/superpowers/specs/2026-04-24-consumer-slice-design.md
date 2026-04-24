# Event Hub inspector consumer — design

**Date:** 2026-04-24
**Location:** `apps/consumer/` (new) + one resource appended to `terraform/guardianlink-dev/eventhubs.tf`
**Slice scope:** close the loop on the ingest pipeline minimally. One small TF edit + one local Python app.

## Purpose

Build a local Python consumer that reads events from the `telemetry` Event Hub, decodes them, and logs them — both to stdout and to App Insights. Running the simulator + consumer side-by-side proves the end-to-end device-ingest pipeline works, round-tripping messages through Azure. No writes to storage or downstream systems; this is pure observation.

This slice deliberately does NOT build a Function-App-based consumer. That's the right long-term shape but a multi-slice commitment (Storage + Function App + code). Getting a working local consumer first validates the pipeline without locking in compute choices.

## Context

Current state (commit `879a48e`): ingest path complete from simulator → IoT Hub → `telemetry` Event Hub. Simulator runs locally; IoT Hub has SAS devices; Event Hubs namespace has `local_authentication_enabled = false` (Entra-only). No consumer exists.

Architecture commits (`docs/architecture.md`):
- Python for workers and dev tools.
- Managed identities / Entra everywhere; no SAS between services.
- Telemetry-writer Function eventually reads this hub and writes to Blob + Cosmos; this consumer is a demo-focused precursor, not a replacement.

## Terraform change

Append to `terraform/guardianlink-dev/eventhubs.tf`:

```hcl
# Consumer group for the local inspector consumer in apps/consumer/.
# Kept separate from any future telemetry-writer Function's group so
# multiple consumers can run without partition-ownership conflicts.
resource "azurerm_eventhub_consumer_group" "inspector" {
  provider = azurerm.workload

  name                = "inspector"
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.telemetry.name
  resource_group_name = azurerm_resource_group.main.name
}
```

Single new resource. No other TF changes.

## Python app layout

```
apps/consumer/
  bootstrap.py           # grants Data Receiver role, writes .env (idempotent)
  consumer.py            # async EH consumer; logs to stdout + App Insights
  format.py              # pure function(s) to turn an EventData into a string
  tests/
    __init__.py          # empty
    test_format.py       # unit tests
  requirements.txt
  requirements-dev.txt
  .env.example           # committed; placeholder values
  README.md              # bootstrap + run instructions
```

Layout mirrors `apps/simulator/` so patterns and mental model carry over.

## Components

### `bootstrap.py`

Responsibility: make sure the user's `az`-logged-in principal can receive from the `telemetry` hub, and persist the one secret it can't hardcode (App Insights connection string) to `.env`.

Behavior:
1. `az ad signed-in-user show --query id -o tsv` → current Entra object ID.
2. Compute the hub's ARM resource ID from hardcoded names (subscription, RG, namespace, hub).
3. `az role assignment create --role "Azure Event Hubs Data Receiver" --scope <hub-id> --assignee-object-id <oid> --assignee-principal-type User`. Swallow `RoleAssignmentExists` errors so re-runs are idempotent.
4. `az monitor app-insights component show ... --query connectionString -o tsv` → AI connection string.
5. Write `.env` with:
   ```
   EVENT_HUB_FQDN=evhns-guardianlink-dev-weu.servicebus.windows.net
   EVENT_HUB_NAME=telemetry
   CONSUMER_GROUP=inspector
   STARTING_POSITION=@latest
   APPLICATIONINSIGHTS_CONNECTION_STRING=<fetched>
   ```

Hardcoded values:
- `SUBSCRIPTION_ID = "WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER"`
- `RESOURCE_GROUP = "rg-guardianlink-dev"`
- `NAMESPACE = "evhns-guardianlink-dev-weu"`
- `EVENT_HUB = "telemetry"`
- `CONSUMER_GROUP = "inspector"`
- `APPINSIGHTS_NAME = "appi-guardianlink-dev-weu"`

Azure RBAC propagation: after granting the role, wait ~30–60s before the first consumer run if the role didn't exist yet. Document this in the README; don't loop-retry in bootstrap.

### `consumer.py`

Responsibility: read events from the `telemetry` hub, decode them, log once per event to stdout + App Insights.

Behavior:
- Load `.env`; `logging.basicConfig` → `configure_azure_monitor` (order matters — learned from simulator slice).
- Build `DefaultAzureCredential`.
- Build `EventHubConsumerClient(fully_qualified_namespace=..., eventhub_name=..., consumer_group=..., credential=...)` (from `azure.eventhub.aio`).
- Start receiving from `STARTING_POSITION` across all partitions with `client.receive(on_event=on_event, starting_position="@latest")`. `@latest` means "new events only" — historical messages from before the consumer started are skipped. Fine for a demo inspector.
- `on_event(partition_context, event)`:
  - Decode `event.body_as_str()` as JSON → `body: dict`.
  - `event_type = event.properties.get(b"eventType", b"").decode()` (EH properties are bytes).
  - Format via `format.format_event(body, event_type, partition_context.partition_id, event.enqueued_time)` → stdout.
  - Log `message_received` with `extra={"event_type": event_type, "partition_id": partition_context.partition_id, "device_id": body.get("device_id", "")}`.
  - (No `partition_context.update_checkpoint()` — no checkpoint store configured.)
- On Ctrl-C (SIGINT/SIGTERM): set asyncio.Event, cancel the receive task, `await client.close()`.

No retry/backoff beyond what the SDK provides. No partition-level state. One run = one session; restart reads only new events.

### `format.py`

Pure function, no I/O. Testable.

```python
def format_event(body: dict, event_type: str, partition_id: str, enqueued_time: datetime) -> str:
    """One-line human-readable summary pulling out fields that matter at a glance."""
```

Output shape:
```
[p=1 telemetry sim-01 @ 2026-04-24T19:49:13] HR=73 bat=87.2% accel=(0.12,-0.05,0.98)
```

Crash-suspect variant adds `conf=<suspect_confidence>` before the accel triple.

Missing/None fields handled safely: `body.get("heart_rate_bpm", "?")`, `body.get("accelerometer") or {}`, etc. Never `KeyError`.

### `tests/test_format.py`

- `test_telemetry_format_includes_core_fields` — asserts the string contains `"telemetry"`, device ID, partition, HR, battery, three accelerometer axes.
- `test_crash_suspect_includes_confidence` — asserts the string contains `"crash_suspect"` and `conf=`.
- `test_missing_fields_tolerated` — empty-ish body should format without raising.
- `test_enqueued_time_iso_formatted` — timestamp renders in ISO-8601.

No network tests. Same policy as the simulator slice.

### Dependencies

`requirements.txt`:
```
azure-eventhub>=5.12
azure-identity>=1.19
azure-monitor-opentelemetry>=1.6
python-dotenv>=1.0
```

Note: `azure-eventhub` does NOT have the undeclared `six` dependency that `azure-iot-hub` has. Different package, cleaner deps.

`requirements-dev.txt`:
```
-r requirements.txt
pytest>=8
ruff>=0.6
```

Python 3.10+.

## App Insights instrumentation

Same mechanism as `apps/simulator`:
- `logging.basicConfig(level=logging.INFO, format=...)` BEFORE `configure_azure_monitor(...)`. Reversed order makes basicConfig a no-op and silences stderr.
- `extra={<key>: <value>, ...}` directly under `extra` — do NOT nest under `custom_dimensions`. The OTel distro stringifies nested dicts; Kusto queries on `customDimensions.event_type` would return empty strings.

Logged events:

| Message | Dimensions | When |
|---|---|---|
| `consumer_started` | `consumer_group` | After `client.receive()` starts |
| `message_received` | `event_type`, `partition_id`, `device_id` | Each event |
| `message_decode_failed` | `partition_id`, `error` | JSON decode / property extraction fails |

## Verification after running

With simulator running in one terminal, consumer in another:

1. **Consumer stdout** shows 1 formatted line per simulator message, including `p=<0–3>` partition IDs (4 partitions total).
2. **`eventType`** surfaces as `telemetry` or `crash_suspect` — matching the simulator's property tagging.
3. **App Insights**:
   ```
   traces
   | where timestamp > ago(10m)
   | where message == "message_received"
   | summarize count() by tostring(customDimensions.event_type)
   ```
   Mirrors the simulator's `message_sent` counts (with ingestion-lag delay, typically a few seconds for EH + minutes for AI).
4. **Both Ctrl-C cleanly** without traceback.

## Risks and notes

- **Role propagation lag.** Freshly granted Data Receiver can take ~30–60s before EH accepts it. First run after bootstrap may fail auth; retry after a minute. Don't paper over this with an auto-retry loop in the code — it masks real auth bugs.
- **`@latest` means new-only.** Running the consumer AFTER the simulator already sent messages will skip those. Start the consumer first, or accept the lost early events.
- **No checkpointing.** Restarts lose position. Acceptable: this is a local inspector, not a durable processor.
- **4 partitions on the hub.** Events hash by `device_id` (IoT Hub's default from `DeviceMessages` source). With only `sim-01` producing, all messages land on one partition. Seeing all four partitions exercised requires multiple device IDs — future slice concern.
- **F1 IoT Hub cap still applies.** Nothing in this slice adds traffic; consuming doesn't count against the 8000/day.
- **User-principal RBAC.** Role granted at hub scope (`azurerm_eventhub.telemetry.id`), not namespace, matching the IoT-Hub-to-EH role's scoping pattern. Hub-scoped.

## Done criteria

- `terraform apply` adds exactly 1 resource (`azurerm_eventhub_consumer_group.inspector`); no drift on re-plan.
- `python -m pytest` in `apps/consumer/` passes all tests.
- `python bootstrap.py` is idempotent (second run returns `role already exists`, rewrites `.env`).
- `python consumer.py` runs for ≥ 1 minute alongside an active simulator; consumer sees at least one telemetry message formatted with expected fields.
- All four verification checks above return the expected results.
- Spec + plan + TF edit + Python code land in one commit.
