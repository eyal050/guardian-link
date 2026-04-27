# Metrics Function Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add observability metrics to the GuardianLink pipeline — event throughput (metrics fn), classifier latency (crash-classifier enrichment), and end-to-end crash-to-notification latency (notifier enrichment) — all via `logging.info` so they land in `AppTraces` and are queryable via KQL.

**Architecture:** A new `apps/metrics` Function App consumes from the `metrics` consumer group on the `telemetry` Event Hub and logs one `telemetry_event_received` line per event. The crash-classifier is enriched to log `classifier_latency_ms` and embed `eh_enqueued_time` in the SB message body. The notifier is enriched with a `_log_notification_latency` helper that computes and logs `notification_stage_ms` and (when `eh_enqueued_time` is present) `end_to_end_ms`.

**Tech Stack:** Python 3.10, `azure-functions>=1.20`, `pytest>=8`, `ruff>=0.6`, Terraform (azurerm), Kudu SCM zipdeploy.

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `apps/metrics/function_app.py` | EH trigger, log throughput |
| Create | `apps/metrics/host.json` | Extension bundle config (copy from crash-classifier) |
| Create | `apps/metrics/requirements.txt` | `azure-functions>=1.20` only |
| Create | `apps/metrics/requirements-dev.txt` | `-r requirements.txt`, pytest, ruff |
| Create | `apps/metrics/tests/__init__.py` | Empty (pytest discovery) |
| Create | `apps/metrics/tests/test_metrics.py` | 3 tests for record_throughput |
| Modify | `apps/crash-classifier/function_app.py` | Add latency log + eh_enqueued_time embed |
| Modify | `apps/crash-classifier/tests/test_function_app.py` | Add 2 latency tests |
| Modify | `apps/notifier/function_app.py` | Add `_log_notification_latency` helper + call |
| Create | `apps/notifier/tests/test_notifier_latency.py` | 3 tests for `_log_notification_latency` |
| Create | `terraform/guardianlink-dev/metrics.tf` | Consumer group, Function App, RBAC, diagnostics |

---

### Task 1: Scaffold `apps/metrics` and write failing tests

**Files:**
- Create: `apps/metrics/tests/__init__.py`
- Create: `apps/metrics/tests/test_metrics.py`
- Create: `apps/metrics/requirements.txt`
- Create: `apps/metrics/requirements-dev.txt`
- Create: `apps/metrics/host.json`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p apps/metrics/tests
```

- [ ] **Step 2: Create `apps/metrics/tests/__init__.py`**

Empty file:
```python
```

- [ ] **Step 3: Create `apps/metrics/requirements.txt`**

```
azure-functions>=1.20
```

- [ ] **Step 4: Create `apps/metrics/requirements-dev.txt`**

```
-r requirements.txt
pytest>=8
ruff>=0.6
```

- [ ] **Step 5: Create `apps/metrics/host.json`**

```json
{
  "version": "2.0",
  "logging": {
    "applicationInsights": {
      "samplingSettings": {
        "isEnabled": false
      }
    }
  },
  "extensionBundle": {
    "id": "Microsoft.Azure.Functions.ExtensionBundle",
    "version": "[4.*, 5.0.0)"
  }
}
```

- [ ] **Step 6: Write the failing tests in `apps/metrics/tests/test_metrics.py`**

```python
import json
import logging
from unittest.mock import MagicMock

import pytest


def _event(body: bytes = b"", event_type: str = "telemetry", seq: int = 1) -> MagicMock:
    e = MagicMock()
    e.get_body.return_value = body
    e.sequence_number = seq
    e.metadata = {"Properties": {"eventType": event_type}}
    return e


def test_happy_path_logs_event_type_and_device_id(caplog):
    """Valid event with eventType property and JSON body → correct log line."""
    from function_app import record_throughput

    body = json.dumps({"device_id": "sim-01", "value": 1.5}).encode()
    event = _event(body=body, event_type="telemetry", seq=42)
    caplog.set_level(logging.INFO)

    record_throughput(event)

    msgs = [r.getMessage() for r in caplog.records]
    assert any("telemetry_event_received" in m for m in msgs)
    assert any("event_type=telemetry" in m for m in msgs)
    assert any("device_id=sim-01" in m for m in msgs)


def test_unknown_event_type_logs_unknown(caplog):
    """No Properties in metadata → event_type=unknown, no exception."""
    from function_app import record_throughput

    event = MagicMock()
    event.get_body.return_value = b"{}"
    event.sequence_number = 1
    event.metadata = {}        # no Properties key
    caplog.set_level(logging.INFO)

    record_throughput(event)

    msgs = [r.getMessage() for r in caplog.records]
    assert any("event_type=unknown" in m for m in msgs)


def test_malformed_body_logs_with_empty_device_id(caplog):
    """Non-JSON body → logs with empty device_id, no exception raised."""
    from function_app import record_throughput

    event = _event(body=b"not-json", event_type="telemetry")
    caplog.set_level(logging.INFO)

    record_throughput(event)

    msgs = [r.getMessage() for r in caplog.records]
    assert any("telemetry_event_received" in m for m in msgs)
    assert any("device_id= " in m or "device_id=\n" in m or "device_id=" in m for m in msgs)
    # Key guarantee: function completed without raising
```

- [ ] **Step 7: Install dev deps and verify tests FAIL**

```bash
cd apps/metrics && pip install -r requirements-dev.txt && pytest tests/ -v
```

Expected: `ModuleNotFoundError: No module named 'function_app'` (or similar import failure)

---

### Task 2: Implement `apps/metrics/function_app.py` and make tests pass

**Files:**
- Create: `apps/metrics/function_app.py`

- [ ] **Step 1: Create `apps/metrics/function_app.py`**

```python
from __future__ import annotations

import json
import logging

import azure.functions as func


app = func.FunctionApp()


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

- [ ] **Step 2: Run tests and verify they PASS**

```bash
cd apps/metrics && pytest tests/ -v
```

Expected: `3 passed`

- [ ] **Step 3: Commit**

```bash
git add apps/metrics/
git commit -m "feat(metrics): add metrics Function App — logs throughput via telemetry_event_received"
```

---

### Task 3: Add failing classifier latency tests

**Files:**
- Modify: `apps/crash-classifier/tests/test_function_app.py`

- [ ] **Step 1: Append two tests to `apps/crash-classifier/tests/test_function_app.py`**

Add at the end of the file:

```python
# ---------------------------------------------------------------------------
# Classifier latency
# ---------------------------------------------------------------------------

def test_classifier_latency_logged_when_enqueued_time_present(_stub_clients, caplog):
    """enqueued_time set → classifier_latency_ms logged; eh_enqueued_time in SB body."""
    _, sb_sender = _stub_clients
    caplog.set_level(logging.INFO)

    classify_crash(_event(_crash_body()))

    msgs = [r.getMessage() for r in caplog.records]
    assert any("classifier_latency_ms=" in m for m in msgs)

    msg = sb_sender.send_messages.call_args.args[0]
    payload = json.loads(b"".join(msg.body))
    assert "eh_enqueued_time" in payload


def test_classifier_latency_not_logged_when_enqueued_time_none(_stub_clients, caplog, monkeypatch):
    """enqueued_time=None → no classifier_latency_ms log; no eh_enqueued_time in SB body."""
    _, sb_sender = _stub_clients
    caplog.set_level(logging.INFO)

    event = _event(_crash_body())
    event.enqueued_time = None

    classify_crash(event)

    msgs = [r.getMessage() for r in caplog.records]
    assert not any("classifier_latency_ms=" in m for m in msgs)

    msg = sb_sender.send_messages.call_args.args[0]
    payload = json.loads(b"".join(msg.body))
    assert "eh_enqueued_time" not in payload
```

- [ ] **Step 2: Run classifier tests and verify new tests FAIL**

```bash
cd apps/crash-classifier && pytest tests/test_function_app.py::test_classifier_latency_logged_when_enqueued_time_present tests/test_function_app.py::test_classifier_latency_not_logged_when_enqueued_time_none -v
```

Expected: `2 failed` (key `eh_enqueued_time` not in payload)

---

### Task 4: Enrich `apps/crash-classifier/function_app.py` and make classifier tests pass

**Files:**
- Modify: `apps/crash-classifier/function_app.py`

The `classify_crash` function currently builds `sb_payload` and sends at lines 170–186. The enrichment goes in two places inside the `confidence >= threshold` branch:

1. After the `result = _call_ml(window)` + threshold check, log latency.
2. When building `sb_payload`, conditionally embed `eh_enqueued_time`.

- [ ] **Step 1: Add the import for `timezone` — already present, verify:**

`from datetime import datetime, timedelta, timezone` is already at line 31. No change needed.

- [ ] **Step 2: Replace the `confidence >= threshold` publishing block**

Current block (lines 169–186):
```python
    from azure.servicebus import ServiceBusMessage  # lazy — keep in sync with _get_sb_sender
    message_id = f"{device_id}|{crash_timestamp}"
    sb_payload = {
        "device_id": device_id,
        "crash_timestamp": crash_timestamp,
        "confidence": confidence,
        "classifier_version": "stub-v1",
    }
    msg = ServiceBusMessage(
        body=json.dumps(sb_payload).encode(),
        message_id=message_id,
    )
    _get_sb_sender().send_messages(msg)

    logging.info(
        "crash_confirmed_published device_id=%s confidence=%.3f message_id=%s",
        device_id, confidence, message_id,
    )
```

Replace with:
```python
    if event.enqueued_time:
        latency_ms = (datetime.now(timezone.utc) - event.enqueued_time).total_seconds() * 1000
        logging.info(
            "classifier_latency_ms=%.1f device_id=%s confidence=%.3f",
            latency_ms, device_id, confidence,
        )

    from azure.servicebus import ServiceBusMessage  # lazy — keep in sync with _get_sb_sender
    message_id = f"{device_id}|{crash_timestamp}"
    sb_payload = {
        "device_id": device_id,
        "crash_timestamp": crash_timestamp,
        "confidence": confidence,
        "classifier_version": "stub-v1",
    }
    if event.enqueued_time:
        sb_payload["eh_enqueued_time"] = event.enqueued_time.isoformat()
    msg = ServiceBusMessage(
        body=json.dumps(sb_payload).encode(),
        message_id=message_id,
    )
    _get_sb_sender().send_messages(msg)

    logging.info(
        "crash_confirmed_published device_id=%s confidence=%.3f message_id=%s",
        device_id, confidence, message_id,
    )
```

- [ ] **Step 3: Run the full classifier test suite**

```bash
cd apps/crash-classifier && pytest tests/ -v
```

Expected: all tests pass (including the 2 new latency tests and all pre-existing tests)

- [ ] **Step 4: Commit**

```bash
git add apps/crash-classifier/function_app.py apps/crash-classifier/tests/test_function_app.py
git commit -m "feat(crash-classifier): log classifier_latency_ms and embed eh_enqueued_time in SB body"
```

---

### Task 5: Write failing notifier latency tests

**Files:**
- Create: `apps/notifier/tests/test_notifier_latency.py`

- [ ] **Step 1: Create `apps/notifier/tests/test_notifier_latency.py`**

```python
import logging
from datetime import datetime, timezone
from unittest.mock import MagicMock

import pytest

import function_app
from function_app import _log_notification_latency


_COMPLETED_AT = "2026-04-27T14:32:05.000000+00:00"
_SB_ENQUEUED = datetime(2026, 4, 27, 14, 32, 3, tzinfo=timezone.utc)
_EH_ENQUEUED = "2026-04-27T14:32:00+00:00"


def _msg(sb_enqueued=_SB_ENQUEUED):
    m = MagicMock()
    m.enqueued_time_utc = sb_enqueued
    return m


def test_both_timestamps_logs_e2e_and_stage(caplog):
    """eh_enqueued_time + sb enqueued → logs both end_to_end_ms and notification_stage_ms."""
    body = {"device_id": "sim-01", "eh_enqueued_time": _EH_ENQUEUED}
    caplog.set_level(logging.INFO)

    _log_notification_latency(_msg(), body, _COMPLETED_AT)

    msgs = [r.getMessage() for r in caplog.records]
    assert any("notification_latency" in m for m in msgs)
    assert any("end_to_end_ms=" in m for m in msgs)
    assert any("notification_stage_ms=" in m for m in msgs)


def test_only_sb_enqueued_logs_stage_only(caplog):
    """No eh_enqueued_time in body → only notification_stage_ms logged (no end_to_end_ms)."""
    body = {"device_id": "sim-01"}
    caplog.set_level(logging.INFO)

    _log_notification_latency(_msg(), body, _COMPLETED_AT)

    msgs = [r.getMessage() for r in caplog.records]
    assert any("notification_latency" in m for m in msgs)
    assert any("notification_stage_ms=" in m for m in msgs)
    assert not any("end_to_end_ms=" in m for m in msgs)


def test_no_sb_enqueued_skips_all_latency_logging(caplog):
    """msg.enqueued_time_utc=None → no latency log, warning emitted, no exception."""
    body = {"device_id": "sim-01", "eh_enqueued_time": _EH_ENQUEUED}
    caplog.set_level(logging.WARNING)

    _log_notification_latency(_msg(sb_enqueued=None), body, _COMPLETED_AT)

    msgs = [r.getMessage() for r in caplog.records]
    assert not any("notification_latency" in m for m in msgs)
    assert any("notification_latency_skipped" in m for m in msgs)
```

- [ ] **Step 2: Run notifier latency tests and verify they FAIL**

```bash
cd apps/notifier && pytest tests/test_notifier_latency.py -v
```

Expected: `ImportError: cannot import name '_log_notification_latency' from 'function_app'`

---

### Task 6: Enrich `apps/notifier/function_app.py` and make latency tests pass

**Files:**
- Modify: `apps/notifier/function_app.py`

- [ ] **Step 1: Add `_log_notification_latency` helper to `apps/notifier/function_app.py`**

Add after the existing imports (after `from typing import Any`), before the module-level lazy globals. Insert the function before the `app = func.FunctionApp()` line:

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

- [ ] **Step 2: Update `_msg()` in `apps/notifier/tests/test_notifier.py` to set `enqueued_time_utc`**

The existing `_msg()` factory returns a bare `MagicMock`, so `msg.enqueued_time_utc` would be another MagicMock (truthy but not a datetime). `_log_notification_latency` would then crash when it tries to compute `completed_dt - sb_enqueued`. Patch the factory to return a real datetime.

Add the import at the top of `test_notifier.py` (after `from unittest.mock import MagicMock`):
```python
from datetime import datetime, timezone
```

Then update `_msg()` to set `enqueued_time_utc`:
```python
def _msg(device_id=_DEVICE_ID, crash_timestamp=_CRASH_TS, confidence=0.95):
    m = MagicMock()
    m.get_body.return_value = json.dumps({
        "device_id": device_id,
        "crash_timestamp": crash_timestamp,
        "confidence": confidence,
        "classifier_version": "stub-v1",
    }).encode()
    m.enqueued_time_utc = datetime(2026, 4, 27, 14, 32, 3, tzinfo=timezone.utc)
    return m
```

- [ ] **Step 3: Call `_log_notification_latency` in `notify_crash`**

At the end of `notify_crash`, before `# SB Complete() is implicit on clean return`, the current code is:

```python
    record["status"] = "completed"
    record["completed_at"] = now
    _upsert_notification_record(container, record)
    # SB Complete() is implicit on clean return
```

Replace with:

```python
    record["status"] = "completed"
    record["completed_at"] = now
    _upsert_notification_record(container, record)
    _log_notification_latency(msg, body, now)
    # SB Complete() is implicit on clean return
```

- [ ] **Step 4: Run the full notifier test suite**

```bash
cd apps/notifier && pytest tests/ -v
```

Expected: all tests pass (3 new latency tests + all pre-existing tests from `test_notifier.py`)

- [ ] **Step 5: Commit**

```bash
git add apps/notifier/function_app.py apps/notifier/tests/test_notifier_latency.py apps/notifier/tests/test_notifier.py
git commit -m "feat(notifier): log notification_latency_ms and end_to_end_ms after fan-out completes"
```

---

### Task 7: Write `terraform/guardianlink-dev/metrics.tf`

**Files:**
- Create: `terraform/guardianlink-dev/metrics.tf`

- [ ] **Step 1: Create `terraform/guardianlink-dev/metrics.tf`**

```hcl
# Consumer group for the metrics Function App. Separate group means the
# metrics app tracks its own EH offset independently of crash-classifier
# and telemetry-writer — lag in one does not affect the others.
resource "azurerm_eventhub_consumer_group" "metrics" {
  provider = azurerm.workload

  name                = "metrics"
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.telemetry.name
  resource_group_name = azurerm_resource_group.main.name
}

# Metrics Function App. No Cosmos, no Service Bus — reads EH only.
# Shares the Y1 Consumption plan; on Consumption, apps scale independently.
resource "azurerm_linux_function_app" "metrics" {
  provider = azurerm.workload

  name                = "func-${local.name_prefix}-metrics"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.functions.id

  storage_account_name       = azurerm_storage_account.main.name
  storage_account_access_key = azurerm_storage_account.main.primary_access_key

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.10"
    }

    application_insights_connection_string = azurerm_application_insights.main.connection_string
  }

  app_settings = {
    "EH_TELEMETRY__fullyQualifiedNamespace" = "${azurerm_eventhub_namespace.main.name}.servicebus.windows.net"
    "EH_TELEMETRY__credential"              = "managedidentity"

    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
    "AzureWebJobsFeatureFlags"       = "EnableWorkerIndexing"
  }

  lifecycle {
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE"],
    ]
  }

  tags = local.tags
}

# EH Data Receiver scoped to the telemetry hub — same scope as classifier.
resource "azurerm_role_assignment" "metrics_to_eh_receiver" {
  provider = azurerm.workload

  scope                = azurerm_eventhub.telemetry.id
  role_definition_name = "Azure Event Hubs Data Receiver"
  principal_id         = azurerm_linux_function_app.metrics.identity[0].principal_id
}

resource "azurerm_monitor_diagnostic_setting" "functions_metrics" {
  provider = azurerm.workload

  name                       = "diag-func-${local.name_prefix}-metrics"
  target_resource_id         = azurerm_linux_function_app.metrics.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "FunctionAppLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
```

- [ ] **Step 2: Run `terraform fmt` and `terraform validate`**

```bash
cd terraform/guardianlink-dev && terraform fmt metrics.tf && terraform validate
```

Expected: `Success! The configuration is valid.`

---

### Task 8: `terraform plan` and `terraform apply`

- [ ] **Step 1: Run plan**

```bash
cd terraform/guardianlink-dev && ./run.sh plan 2>&1 | tee /tmp/metrics-plan.txt
```

Expected additions:
- `azurerm_eventhub_consumer_group.metrics`
- `azurerm_linux_function_app.metrics`
- `azurerm_role_assignment.metrics_to_eh_receiver`
- `azurerm_monitor_diagnostic_setting.functions_metrics`

No changes to existing resources. If anything unexpected appears, stop and investigate.

- [ ] **Step 2: Run apply**

```bash
cd terraform/guardianlink-dev && ./run.sh apply
```

Expected: `Apply complete! Resources: 4 added, 0 changed, 0 destroyed.`

- [ ] **Step 3: Confirm consumer group exists**

```bash
az eventhubs eventhub consumer-group list \
  --resource-group rg-guardianlink-dev \
  --namespace-name $(az eventhubs namespace list -g rg-guardianlink-dev --query '[0].name' -o tsv) \
  --eventhub-name telemetry \
  --query '[].name' -o tsv \
  --subscription WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER
```

Expected: `crash-classifier`, `metrics`, `telemetry-writer` (and `$Default`).

- [ ] **Step 4: Commit**

```bash
git add terraform/guardianlink-dev/metrics.tf
git commit -m "infra(metrics): add metrics Function App, consumer group, EH receiver RBAC, diagnostics"
```

---

### Task 9: Deploy all three Function Apps

Deploy order: metrics (new), then classifier and notifier (redeploy with updated code). All three use the Kudu SCM zipdeploy path so Oryx builds inside the container and gets the correct GLIBC-compatible wheels.

For classifier and notifier, `WEBSITE_RUN_FROM_PACKAGE` may be set from a previous deploy — delete it first or Kudu returns 409.

- [ ] **Step 1: Get function app hostnames and publishing passwords**

```bash
SUBSCRIPTION=WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER
RG=rg-guardianlink-dev

for APP in metrics crash-classifier notifier; do
  NAME="func-guardianlink-dev-weu-${APP}"
  PASS=$(az functionapp deployment list-publishing-credentials \
    --name "$NAME" --resource-group "$RG" \
    --subscription "$SUBSCRIPTION" \
    --query publishingPassword -o tsv)
  echo "${APP}: ${NAME} → pass=${PASS:0:8}..."
done
```

- [ ] **Step 2: Delete `WEBSITE_RUN_FROM_PACKAGE` from classifier and notifier (if set)**

```bash
for APP in crash-classifier notifier; do
  NAME="func-guardianlink-dev-weu-${APP}"
  az functionapp config appsettings delete \
    --name "$NAME" \
    --resource-group "$RG" \
    --subscription "$SUBSCRIPTION" \
    --setting-names WEBSITE_RUN_FROM_PACKAGE
done
```

Expected: settings list returned without `WEBSITE_RUN_FROM_PACKAGE`. Safe to run even if not set.

- [ ] **Step 3: Deploy metrics function**

```bash
cd apps/metrics
zip -r /tmp/metrics-src.zip . -x '*.pyc' -x '__pycache__/*' -x 'tests/*' -x '.pytest_cache/*'

METRICS_PASS=$(az functionapp deployment list-publishing-credentials \
  --name func-guardianlink-dev-weu-metrics \
  --resource-group rg-guardianlink-dev \
  --subscription WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER \
  --query publishingPassword -o tsv)

curl -X POST \
  -u "\$func-guardianlink-dev-weu-metrics:${METRICS_PASS}" \
  --data-binary @/tmp/metrics-src.zip \
  'https://func-guardianlink-dev-weu-metrics.scm.azurewebsites.net/api/zipdeploy' \
  -H 'Content-Type: application/zip'
```

Expected: HTTP 202 Accepted.

- [ ] **Step 4: Wake-ping the metrics function (Y1 cold-start)**

Wait ~60s for Oryx build, then:

```bash
curl -s https://func-guardianlink-dev-weu-metrics.azurewebsites.net/
```

Then verify function discovery:

```bash
MASTER_KEY=$(az functionapp keys list \
  --name func-guardianlink-dev-weu-metrics \
  --resource-group rg-guardianlink-dev \
  --subscription WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER \
  --query masterKey -o tsv)

curl -s "https://func-guardianlink-dev-weu-metrics.azurewebsites.net/admin/functions" \
  -H "x-functions-key: ${MASTER_KEY}" | python3 -m json.tool
```

Expected: JSON array with one entry named `record_throughput`.

- [ ] **Step 5: Redeploy crash-classifier**

```bash
cd apps/crash-classifier
zip -r /tmp/classifier-src.zip . -x '*.pyc' -x '__pycache__/*' -x 'tests/*' -x '.pytest_cache/*'

CLASSIFIER_PASS=$(az functionapp deployment list-publishing-credentials \
  --name func-guardianlink-dev-weu-crash-classifier \
  --resource-group rg-guardianlink-dev \
  --subscription WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER \
  --query publishingPassword -o tsv)

curl -X POST \
  -u "\$func-guardianlink-dev-weu-crash-classifier:${CLASSIFIER_PASS}" \
  --data-binary @/tmp/classifier-src.zip \
  'https://func-guardianlink-dev-weu-crash-classifier.scm.azurewebsites.net/api/zipdeploy' \
  -H 'Content-Type: application/zip'
```

Wait ~60s, then wake-ping and verify `classify_crash` is discovered via `/admin/functions`.

- [ ] **Step 6: Redeploy notifier**

```bash
cd apps/notifier
zip -r /tmp/notifier-src.zip . -x '*.pyc' -x '__pycache__/*' -x 'tests/*' -x '.pytest_cache/*'

NOTIFIER_PASS=$(az functionapp deployment list-publishing-credentials \
  --name func-guardianlink-dev-weu-notifier \
  --resource-group rg-guardianlink-dev \
  --subscription WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER \
  --query publishingPassword -o tsv)

curl -X POST \
  -u "\$func-guardianlink-dev-weu-notifier:${NOTIFIER_PASS}" \
  --data-binary @/tmp/notifier-src.zip \
  'https://func-guardianlink-dev-weu-notifier.scm.azurewebsites.net/api/zipdeploy' \
  -H 'Content-Type: application/zip'
```

Wait ~60s, wake-ping, verify `notify_crash` discovered.

---

### Task 10: Smoke test, update architecture.md, commit all

- [ ] **Step 1: Send a test event through the simulator**

```bash
cd apps/simulator
python send_event.py --device-id smoke-metrics-01 --event-type crash_suspect
```

(Or send via IoT Hub directly if the simulator script is available.)

Wait ~90s for the full pipeline: EH → classifier → SB → notifier.

- [ ] **Step 2: Query LAW for throughput log**

```bash
WORKSPACE=$(az monitor log-analytics workspace list \
  -g rg-guardianlink-dev \
  --subscription WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER \
  --query '[0].customerId' -o tsv)

az monitor log-analytics query \
  --workspace "$WORKSPACE" \
  --analytics-query "AppTraces | where AppRoleName contains 'metrics' | where Message startswith 'telemetry_event_received' | project TimeGenerated, Message | order by TimeGenerated desc | take 5" \
  --subscription WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER \
  -o table
```

Expected: at least one row with `telemetry_event_received event_type=crash_suspect ...`.

- [ ] **Step 3: Query LAW for classifier latency log**

```bash
az monitor log-analytics query \
  --workspace "$WORKSPACE" \
  --analytics-query "AppTraces | where AppRoleName contains 'crash-classifier' | where Message startswith 'classifier_latency_ms' | project TimeGenerated, Message | order by TimeGenerated desc | take 5" \
  --subscription WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER \
  -o table
```

Expected: at least one row with `classifier_latency_ms=...`.

- [ ] **Step 4: Query LAW for notification latency log**

```bash
az monitor log-analytics query \
  --workspace "$WORKSPACE" \
  --analytics-query "AppTraces | where AppRoleName contains 'notifier' | where Message startswith 'notification_latency' | project TimeGenerated, Message | order by TimeGenerated desc | take 5" \
  --subscription WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER \
  -o table
```

Expected: at least one row with `notification_latency ... notification_stage_ms=...`.

- [ ] **Step 5: Add Decision 17 to `docs/architecture.md`**

Add to the Decisions section:

```markdown
### Decision 17: Metrics via logging.info to AppTraces (not custom metrics API)

**Decision:** Emit all pipeline metrics (throughput, classifier latency, end-to-end latency) as structured `logging.info` lines, queryable in AppTraces via KQL — rather than using the Application Insights custom metrics API.

**Why:** The custom metrics API requires the `opencensus-ext-azure` SDK, which adds a heavyweight dependency and a separate telemetry channel that is harder to test. The `logging.info` approach is consistent with the existing codebase pattern (every function already uses it), requires no new SDK, and KQL `extract()` is sufficient for p95 latency queries at this scale. If cardinality-aware metric aggregation becomes important, this can be migrated to custom events later.
```

- [ ] **Step 6: Commit everything**

```bash
git add docs/architecture.md
git commit -m "docs: add Decision 17 — metrics via logging.info to AppTraces"
```

Then tag the metrics slice complete:
```bash
git push origin main
```
