# Metrics Function Implementation Design

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add observability metrics to the GuardianLink pipeline — event throughput, classifier latency, and end-to-end crash-to-notification latency — using the existing `logging.info` pattern so metrics land in `AppTraces` and are queryable via KQL.

**Approach:** Approach A — dedicated metrics Function App for throughput; latency computed at the source in the classifier and notifier.

---

## Architecture

Three concerns, each computed where the data naturally exists:

```
EH telemetry hub
    ├── telemetry-writer  (consumer group: telemetry-writer)  [unchanged]
    ├── crash-classifier  (consumer group: crash-classifier)  [enriched]
    └── metrics fn        (consumer group: metrics)           [new]
                                │
                                │ logs: telemetry_event_received event_type=X
                                │
                        crash-classifier
                                │ computes: now() - event.enqueued_time
                                │ logs: classifier_latency_ms=X
                                │ embeds: eh_enqueued_time in SB message body
                                ▼
                        SB crash-confirmed queue
                                │
                        notifier
                                │ computes: now() - body["eh_enqueued_time"]  (end-to-end)
                                │ computes: now() - msg.enqueued_time_utc     (notification stage)
                                │ logs: notification_latency end_to_end_ms=X notification_stage_ms=Y
```

## Timestamp Propagation

Three timestamps flow through the pipeline:

| Name | Set by | Available in |
|------|--------|-------------|
| `T0` — EH enqueued time | Event Hubs broker | `event.enqueued_time` in classifier and metrics fn |
| `T1` — SB enqueued time | Service Bus broker | `msg.enqueued_time_utc` in notifier |
| `T2` — notification complete | `datetime.now()` in notifier | notifier |

`T0` is not naturally available in the notifier. The classifier bridges the gap by embedding it as `eh_enqueued_time` in the SB message body.

**Derived metrics:**
- `classifier_latency_ms` = `(classifier's now())` − `T0`
- `notification_stage_ms` = `T2` − `T1`
- `end_to_end_ms` = `T2` − `T0`

**Edge cases:**
- `event.enqueued_time` is `None` → classifier skips latency log and omits `eh_enqueued_time` from SB message body
- `eh_enqueued_time` absent in SB body (old message or above skip) → notifier logs `notification_stage_ms` only
- `msg.enqueued_time_utc` is `None` → notifier skips all latency logging, emits a warning

## Components

### New: `apps/metrics/function_app.py`

EH trigger on consumer group `metrics`. One log line per event. No external calls.

```python
@app.event_hub_message_trigger(
    arg_name="event",
    event_hub_name="telemetry",
    connection="EH_TELEMETRY",
    consumer_group="metrics",
)
def record_throughput(event: func.EventHubEvent) -> None:
    properties = (event.metadata or {}).get("Properties") or {}
    event_type = str(properties.get("eventType", "unknown"))
    body = {}
    try:
        body = json.loads(event.get_body().decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        pass
    logging.info(
        "telemetry_event_received event_type=%s device_id=%s seq=%s",
        event_type,
        body.get("device_id", ""),
        event.sequence_number,
    )
```

`requirements.txt`: `azure-functions>=1.20` only.

**KQL for throughput:**
```kql
AppTraces
| where AppRoleName contains "metrics"
| where Message startswith "telemetry_event_received"
| summarize events = count() by bin(TimeGenerated, 1m),
    event_type = extract("event_type=([^ ]+)", 1, Message)
```

### Enriched: `apps/crash-classifier/function_app.py`

Two additions inside the `crash_suspect` processing path, after the ML call returns:

**1. Log classifier latency** (before publishing to SB):
```python
if event.enqueued_time:
    latency_ms = (datetime.now(timezone.utc) - event.enqueued_time).total_seconds() * 1000
    logging.info(
        "classifier_latency_ms=%.1f device_id=%s confidence=%.3f",
        latency_ms, device_id, confidence,
    )
```

**2. Embed `eh_enqueued_time` in the SB message body** when publishing `crash_confirmed`:
```python
msg_body = {
    "device_id": device_id,
    "crash_timestamp": crash_timestamp,
    "confidence": confidence,
    "classifier_version": "stub-v1",
}
if event.enqueued_time:
    msg_body["eh_enqueued_time"] = event.enqueued_time.isoformat()
```

Both changes are scoped to the `confidence >= threshold` branch. The below-threshold path is unchanged.

**KQL for classifier latency:**
```kql
AppTraces
| where AppRoleName contains "crash-classifier"
| where Message startswith "classifier_latency_ms"
| extend latency_ms = todouble(extract("classifier_latency_ms=([0-9.]+)", 1, Message))
| summarize avg(latency_ms), percentile(latency_ms, 95) by bin(TimeGenerated, 5m)
```

### Enriched: `apps/notifier/function_app.py`

New helper `_log_notification_latency` called after all channels complete, before the final Cosmos upsert:

```python
def _log_notification_latency(
    msg: func.ServiceBusMessage,
    body: dict[str, Any],
    completed_at: str,
) -> None:
    completed_dt = datetime.fromisoformat(completed_at)

    sb_enqueued = msg.enqueued_time_utc
    if sb_enqueued is None:
        logging.warning("notification_latency_skipped reason=no_sb_enqueued_time")
        return

    stage_ms = (completed_dt - sb_enqueued).total_seconds() * 1000

    eh_ts_raw = body.get("eh_enqueued_time")
    e2e_ms = None
    if eh_ts_raw:
        try:
            eh_dt = datetime.fromisoformat(eh_ts_raw)
            e2e_ms = (completed_dt - eh_dt).total_seconds() * 1000
        except ValueError:
            pass

    if e2e_ms is not None:
        logging.info(
            "notification_latency device_id=%s end_to_end_ms=%.1f notification_stage_ms=%.1f",
            body.get("device_id", ""), e2e_ms, stage_ms,
        )
    else:
        logging.info(
            "notification_latency device_id=%s notification_stage_ms=%.1f",
            body.get("device_id", ""), stage_ms,
        )
```

Called at the end of `notify_crash` on the happy path only (after `record["status"] = "completed"`).

**KQL for notification latency:**
```kql
AppTraces
| where AppRoleName contains "notifier"
| where Message startswith "notification_latency"
| extend
    e2e_ms      = todouble(extract("end_to_end_ms=([0-9.]+)", 1, Message)),
    stage_ms    = todouble(extract("notification_stage_ms=([0-9.]+)", 1, Message)),
    device_id   = extract("device_id=([^ ]+)", 1, Message)
| summarize avg(e2e_ms), percentile(e2e_ms, 95), avg(stage_ms) by bin(TimeGenerated, 5m)
```

## Infrastructure (`terraform/guardianlink-dev/metrics.tf`)

- `azurerm_eventhub_consumer_group.metrics` — `metrics` consumer group on the `telemetry` hub
- `azurerm_linux_function_app.metrics` — Function App on shared Y1 plan (`azurerm_service_plan.functions`)
- App settings: `EH_TELEMETRY__fullyQualifiedNamespace`, `EH_TELEMETRY__credential=managedidentity`, `SCM_DO_BUILD_DURING_DEPLOYMENT=true`, `AzureWebJobsFeatureFlags=EnableWorkerIndexing`, standard `AzureWebJobsStorage` / `APPLICATIONINSIGHTS_CONNECTION_STRING` / `FUNCTIONS_WORKER_RUNTIME=python` / `FUNCTIONS_EXTENSION_VERSION=~4`
- `azurerm_role_assignment.metrics_to_eh_receiver` — MI gets `Azure Event Hubs Data Receiver` scoped to the `telemetry` hub
- `azurerm_monitor_diagnostic_setting.metrics` — `FunctionAppLogs` + `AllMetrics` → LAW
- `lifecycle { ignore_changes = [app_settings["WEBSITE_RUN_FROM_PACKAGE"]] }`

No Key Vault, no Cosmos, no Service Bus involvement.

## Tests

### `apps/metrics/tests/test_metrics.py` (new)

- **happy path** — valid event with `eventType` property and JSON body → `telemetry_event_received` logged with correct `event_type` and `device_id`
- **unknown event type** — no `Properties` in metadata → logs `event_type=unknown`, no exception
- **malformed body** — `get_body()` returns non-JSON → logs with empty `device_id`, no exception

### Classifier latency tests (added to `apps/crash-classifier/tests/test_classifier.py`)

- **enqueued_time present** → `classifier_latency_ms=` in log, `eh_enqueued_time` key present in captured SB message body
- **enqueued_time None** → no `classifier_latency_ms` log, no `eh_enqueued_time` key in SB message body

### `apps/notifier/tests/test_notifier_latency.py` (new)

- **both timestamps present** → `notification_latency ... end_to_end_ms=... notification_stage_ms=...` logged
- **only sb enqueued time** (no `eh_enqueued_time` in body) → logs `notification_stage_ms` only
- **both absent** → no latency log, no exception

All tests use `caplog` for log assertion, `monkeypatch` for stubs — consistent with existing test patterns.

## Deployment

Same Kudu SCM zipdeploy path as the notifier:
```bash
# From apps/metrics/
curl -X POST \
  -u '$func-guardianlink-dev-weu-metrics:<password>' \
  --data-binary @/tmp/metrics-src.zip \
  'https://func-guardianlink-dev-weu-metrics.scm.azurewebsites.net/api/zipdeploy' \
  -H 'Content-Type: application/zip'
```

Classifier and notifier redeploys follow the same pattern (delete `WEBSITE_RUN_FROM_PACKAGE`, Kudu SCM deploy).
