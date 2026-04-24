# Device simulator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local Python device simulator (`apps/simulator/`) that registers a SAS-provisioned device `sim-01` in the existing IoT Hub, then pushes telemetry + crash-suspect events through the existing route into the `telemetry` Event Hub, with App Insights instrumentation.

**Architecture:** First non-Terraform slice. New top-level `apps/` directory; inside `apps/simulator/`: `bootstrap.py` (creates device identity via `az` subprocess + writes `.env`), `simulator.py` (async send loops using `azure-iot-device`), `payload.py` (pure functions for message construction, unit-tested with pytest). App Insights instrumentation via `azure-monitor-opentelemetry`; logs land in the `traces` table. Spec: `docs/superpowers/specs/2026-04-24-simulator-slice-design.md`.

**Tech Stack:** Python 3.10+, pytest, `azure-iot-device`, `azure-iot-hub`, `azure-monitor-opentelemetry`, `python-dotenv`. Azure CLI as a runtime prerequisite of `bootstrap.py` (shells out to `az`).

**Pre-existing infra this depends on** (commit `92eac54`):
- IoT Hub `iot-guardianlink-dev-weu` in RG `rg-guardianlink-dev` with SAS auth enabled.
- Event Hub `telemetry` on namespace `evhns-guardianlink-dev-weu`.
- IoT Hub → Event Hub route `route-all-to-telemetry-eh` (source DeviceMessages, condition true).
- App Insights `appi-guardianlink-dev-weu` (workspace-linked).
- Log Analytics workspace `log-guardianlink-dev-weu`.

**Prerequisites on the user's machine:**
- Python 3.10+ (user has 3.10.12).
- Azure CLI logged in against the `guardianlink-dev` child subscription (bootstrap shells out to `az`).
- Ability to create a virtualenv.

**Testing approach:** pytest against `payload.py` pure functions. No integration tests against IoT Hub (too slow, too environmental). End-to-end validation is a manual run + post-run queries against Log Analytics / App Insights / portal.

---

## File Structure

```
apps/simulator/
  bootstrap.py               # ~60 lines: az subprocess → create device → write .env
  simulator.py               # ~100 lines: async send loops + AI instrumentation
  payload.py                 # ~50 lines: pure functions, the only unit-tested module
  tests/
    __init__.py              # empty
    test_payload.py          # ~60 lines
  requirements.txt
  requirements-dev.txt
  .env.example               # committed; placeholder values only
  README.md                  # ~40 lines: how to bootstrap + run + verify
```

Modifications to existing files:
- `.gitignore` — add `.env` at repo root (the existing gitignore has Python sections but not `.env`).

---

## Task 1: Create the apps/simulator scaffold

**Files:**
- Create: `apps/simulator/requirements.txt`, `apps/simulator/requirements-dev.txt`, `apps/simulator/.env.example`, `apps/simulator/README.md`, `apps/simulator/tests/__init__.py`
- Modify: `.gitignore` (append `.env` rule)

- [ ] **Step 1: Append `.env` rule to `.gitignore`**

At the end of `.gitignore` add:

```
# Env files (never commit real secrets)
.env
.env.local
!.env.example
```

Verify the pre-existing Python + Terraform sections are untouched — we are only appending.

- [ ] **Step 2: Create `apps/simulator/requirements.txt`**

```
azure-iot-device>=2.14
azure-iot-hub>=2.6
azure-monitor-opentelemetry>=1.6
python-dotenv>=1.0
```

- [ ] **Step 3: Create `apps/simulator/requirements-dev.txt`**

```
-r requirements.txt
pytest>=8
ruff>=0.6
```

- [ ] **Step 4: Create `apps/simulator/.env.example`**

```
# Populated by bootstrap.py; this template is committed for reference.
IOTHUB_DEVICE_CONNECTION_STRING=HostName=<hub>.azure-devices.net;DeviceId=sim-01;SharedAccessKey=<key>
APPLICATIONINSIGHTS_CONNECTION_STRING=InstrumentationKey=<key>;IngestionEndpoint=https://<region>.in.applicationinsights.azure.com/
DEVICE_ID=sim-01
TELEMETRY_PERIOD_S=20
CRASH_PERIOD_S=120
```

- [ ] **Step 5: Create empty `apps/simulator/tests/__init__.py`**

Just an empty file so pytest treats `tests/` as a package.

- [ ] **Step 6: Create `apps/simulator/README.md`**

```markdown
# GuardianLink device simulator

Local Python process that connects to the `iot-guardianlink-dev-weu`
IoT Hub as SAS-provisioned device `sim-01` and pushes telemetry +
crash-suspect events until Ctrl-C.

## Prerequisites

- Python 3.10+
- Azure CLI logged in against the `guardianlink-dev` subscription:
  `az account show` should return `name: guardianlink-dev`.
- The `guardianlink-dev` Terraform stack applied (IoT Hub + Event Hub
  + App Insights live).

## One-time setup

```bash
cd apps/simulator
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
python -m pytest                  # should pass before running anything live
python bootstrap.py               # registers sim-01, writes .env
```

`bootstrap.py` is idempotent. Re-run it any time the IoT Hub is
recreated (a `terraform destroy`/`apply` cycle resets the device
registry).

## Running

```bash
python simulator.py
# Ctrl-C to stop; disconnects cleanly.
```

## Configuration

Tune via `.env`:
- `TELEMETRY_PERIOD_S` — seconds between telemetry messages (default 20).
- `CRASH_PERIOD_S` — seconds between crash-suspect messages (default 120).

**IoT Hub F1 cap:** 8000 messages/day. Defaults produce ~5040/day
(37% margin). Dropping periods below ~15s will burn the cap within
a workday. The hub silently 429s when the cap is hit.

## Verification

After running ~2 minutes, verify in the child subscription:

1. Portal → IoT Hub → Metrics → "Total number of messages used" ≥ 6.
2. Portal → Event Hub `telemetry` → Data Explorer → messages visible
   with `eventType` property `telemetry` or `crash_suspect`.
3. App Insights Logs:
   ```
   traces | where message == "message_sent"
     | summarize count() by tostring(customDimensions.event_type)
   ```
   Expect majority `telemetry`, a few `crash_suspect`.
4. LAW Logs:
   ```
   AzureDiagnostics
   | where ResourceType == "IOTHUBS" and Category == "Routes"
   | project TimeGenerated, OperationName, ResultType, Level
   | take 20
   ```
   Route-delivery rows for each message.
```

- [ ] **Step 7: Verify directory structure**

```bash
find apps/simulator -type f | sort
```
Expected:
```
apps/simulator/.env.example
apps/simulator/README.md
apps/simulator/requirements-dev.txt
apps/simulator/requirements.txt
apps/simulator/tests/__init__.py
```

---

## Task 2: Install dependencies into a fresh venv

**Files:** none modified; creates `.venv/` which is gitignored.

- [ ] **Step 1: Create and activate venv, install dev requirements**

```bash
cd apps/simulator
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements-dev.txt
```

Expected: pip completes without errors. Some Azure packages may emit deprecation warnings about vendored libs — not fatal.

- [ ] **Step 2: Sanity check the toolchain**

```bash
python -c "import azure.iot.device, azure.iot.hub, azure.monitor.opentelemetry, dotenv; print('ok')"
pytest --version
```
Expected: `ok` + a pytest version line. If imports fail, investigate before writing code.

---

## Task 3: Build `payload.py` via TDD

**Files:**
- Create: `apps/simulator/payload.py`
- Create: `apps/simulator/tests/test_payload.py`

All steps run from `apps/simulator/` with the venv activated.

- [ ] **Step 1: Write all failing tests**

Create `apps/simulator/tests/test_payload.py`:

```python
from datetime import datetime, timezone

import pytest

from payload import build_crash_suspect, build_telemetry


NOW = datetime(2026, 4, 24, 19, 30, 0, tzinfo=timezone.utc)
DEVICE = "sim-01"

REQUIRED_KEYS = {
    "device_id",
    "timestamp",
    "accelerometer",
    "gps",
    "battery_pct",
    "heart_rate_bpm",
    "suspect_confidence",
}


def test_telemetry_has_required_keys():
    payload = build_telemetry(DEVICE, NOW)
    assert set(payload.keys()) == REQUIRED_KEYS
    assert payload["device_id"] == DEVICE


def test_crash_suspect_has_required_keys():
    payload = build_crash_suspect(DEVICE, NOW)
    assert set(payload.keys()) == REQUIRED_KEYS
    assert payload["device_id"] == DEVICE


@pytest.mark.parametrize("i", range(100))
def test_telemetry_value_ranges(i):
    p = build_telemetry(DEVICE, NOW)
    accel = p["accelerometer"]
    assert -1.5 <= accel["x"] <= 1.5
    assert -1.5 <= accel["y"] <= 1.5
    assert -1.5 <= accel["z"] <= 1.5
    assert 52.3671 <= p["gps"]["lat"] <= 52.3681
    assert 4.9036 <= p["gps"]["lon"] <= 4.9046
    assert 20.0 <= p["battery_pct"] <= 100.0
    assert 60 <= p["heart_rate_bpm"] <= 90
    assert isinstance(p["heart_rate_bpm"], int)
    assert p["suspect_confidence"] is None


@pytest.mark.parametrize("i", range(100))
def test_crash_suspect_accelerometer_spikes(i):
    p = build_crash_suspect(DEVICE, NOW)
    accel = p["accelerometer"]
    assert max(abs(accel["x"]), abs(accel["y"]), abs(accel["z"])) >= 3.0


@pytest.mark.parametrize("i", range(100))
def test_crash_suspect_heart_rate_and_confidence(i):
    p = build_crash_suspect(DEVICE, NOW)
    assert 120 <= p["heart_rate_bpm"] <= 180
    assert 0.4 <= p["suspect_confidence"] <= 0.8


def test_timestamp_roundtrips():
    p = build_telemetry(DEVICE, NOW)
    parsed = datetime.fromisoformat(p["timestamp"])
    assert parsed == NOW
    # And again for crash:
    p2 = build_crash_suspect(DEVICE, NOW)
    assert datetime.fromisoformat(p2["timestamp"]) == NOW
```

- [ ] **Step 2: Run tests and verify they fail**

```bash
python -m pytest -v
```
Expected: all tests fail with `ModuleNotFoundError: No module named 'payload'` (or a collection error).

- [ ] **Step 3: Implement `payload.py`**

Create `apps/simulator/payload.py`:

```python
"""Pure functions that construct simulator message payloads.

Kept free of I/O and azure-sdk imports so it's trivially unit-testable.
"""

import random
from datetime import datetime


_HOME_LAT = 52.3676
_HOME_LON = 4.9041


def _common(device_id: str, now: datetime) -> dict:
    return {
        "device_id": device_id,
        "timestamp": now.isoformat(),
        "gps": {
            "lat": _HOME_LAT + random.uniform(-0.0005, 0.0005),
            "lon": _HOME_LON + random.uniform(-0.0005, 0.0005),
        },
        "battery_pct": round(random.uniform(20.0, 100.0), 1),
    }


def build_telemetry(device_id: str, now: datetime) -> dict:
    """Plausible steady-state device reading."""
    p = _common(device_id, now)
    p["accelerometer"] = {
        "x": round(random.uniform(-1.5, 1.5), 3),
        "y": round(random.uniform(-1.5, 1.5), 3),
        "z": round(random.uniform(-1.5, 1.5), 3),
    }
    p["heart_rate_bpm"] = random.randint(60, 90)
    p["suspect_confidence"] = None
    return p


def build_crash_suspect(device_id: str, now: datetime) -> dict:
    """Reading that trips the on-device crash heuristic.

    Distinguished from telemetry only by value ranges. The IoT Hub
    custom property `eventType` (set by the caller) is what
    downstream consumers discriminate on.
    """
    p = _common(device_id, now)
    # Guarantee at least one axis spikes to >=3.0 g; up to ±12 g.
    spike_axis = random.choice(["x", "y", "z"])
    accel = {axis: round(random.uniform(-1.5, 1.5), 3) for axis in ("x", "y", "z")}
    accel[spike_axis] = round(random.choice([-1, 1]) * random.uniform(3.0, 12.0), 3)
    p["accelerometer"] = accel
    p["heart_rate_bpm"] = random.randint(120, 180)
    p["suspect_confidence"] = round(random.uniform(0.4, 0.8), 3)
    return p
```

- [ ] **Step 4: Run tests and verify all pass**

```bash
python -m pytest -v
```
Expected: all tests pass (6 named tests × some parametrized → ~303 total passes). If a parametrized test fails on a particular seed, the ranges are off; tighten them in `payload.py` and re-run. Do not widen the test tolerances.

---

## Task 4: Build `bootstrap.py`

**Files:**
- Create: `apps/simulator/bootstrap.py`

- [ ] **Step 1: Write `bootstrap.py`**

```python
"""One-time bootstrap: register device 'sim-01' in the IoT Hub and
persist its connection string (plus the App Insights connection
string) to .env.

Idempotent — safe to re-run after terraform destroy/apply.
Uses `az` CLI subprocess for both connection-string reads so we
inherit the user's `az login` without needing separate IoT Hub
data-plane RBAC grants.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from azure.iot.hub import IoTHubRegistryManager
from azure.iot.hub.models import AuthenticationMechanism, SymmetricKey


IOTHUB_NAME = "iot-guardianlink-dev-weu"
RESOURCE_GROUP = "rg-guardianlink-dev"
APPINSIGHTS_NAME = "appi-guardianlink-dev-weu"
DEVICE_ID = "sim-01"

DEFAULT_TELEMETRY_PERIOD_S = 20
DEFAULT_CRASH_PERIOD_S = 120


def _az(args: list[str]) -> str:
    """Run an `az` CLI command, return stripped stdout, die loudly on failure."""
    try:
        out = subprocess.run(
            ["az", *args],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"az command failed: az {' '.join(args)}", file=sys.stderr)
        print(e.stderr, file=sys.stderr)
        sys.exit(1)
    if not out:
        print(f"az command returned empty output: az {' '.join(args)}", file=sys.stderr)
        sys.exit(1)
    return out


def get_iothub_owner_conn() -> str:
    return _az([
        "iot", "hub", "connection-string", "show",
        "--hub-name", IOTHUB_NAME,
        "--policy-name", "iothubowner",
        "--query", "connectionString", "-o", "tsv",
    ])


def get_appinsights_conn() -> str:
    return _az([
        "monitor", "app-insights", "component", "show",
        "-g", RESOURCE_GROUP,
        "--app", APPINSIGHTS_NAME,
        "--query", "connectionString", "-o", "tsv",
    ])


def ensure_device(registry: IoTHubRegistryManager, device_id: str) -> str:
    """Return the device's primary connection string, creating the device if absent."""
    try:
        device = registry.get_device(device_id)
        print(f"device '{device_id}' already exists")
    except Exception:
        print(f"creating device '{device_id}'")
        # Pass empty primary/secondary keys -> IoT Hub auto-generates SAS keys.
        device = registry.create_device_with_sas(
            device_id=device_id,
            primary_key=None,
            secondary_key=None,
            status="enabled",
        )
    # Device object exposes .authentication.symmetric_key.primary_key
    primary_key = device.authentication.symmetric_key.primary_key
    host = IOTHUB_NAME + ".azure-devices.net"
    return f"HostName={host};DeviceId={device_id};SharedAccessKey={primary_key}"


def write_env(device_conn: str, ai_conn: str, env_path: Path) -> None:
    lines = [
        f"IOTHUB_DEVICE_CONNECTION_STRING={device_conn}",
        f"APPLICATIONINSIGHTS_CONNECTION_STRING={ai_conn}",
        f"DEVICE_ID={DEVICE_ID}",
        f"TELEMETRY_PERIOD_S={DEFAULT_TELEMETRY_PERIOD_S}",
        f"CRASH_PERIOD_S={DEFAULT_CRASH_PERIOD_S}",
        "",
    ]
    env_path.write_text("\n".join(lines))
    print(f"wrote {env_path}")


def main() -> None:
    print(f"bootstrapping simulator against {IOTHUB_NAME}")
    owner_conn = get_iothub_owner_conn()
    registry = IoTHubRegistryManager.from_connection_string(owner_conn)
    device_conn = ensure_device(registry, DEVICE_ID)
    ai_conn = get_appinsights_conn()
    write_env(device_conn, ai_conn, Path(__file__).parent / ".env")
    print("bootstrap complete")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Import-sanity check** (no Azure calls)

```bash
python -c "import bootstrap; print('ok')"
```
Expected: `ok`. If imports fail, fix before running against live Azure.

*Note:* `azure-iot-hub` SDK has `create_device_with_sas` exposed on `IoTHubRegistryManager`. If the provider rejects the call signature (e.g. `create_device_with_sas(...)` argument count changed), fall back to building a `Device(...)` model with an `AuthenticationMechanism(type="sas", symmetric_key=SymmetricKey(...))` and calling `registry.create_or_update_device(device_id, device)`. Do NOT silently swallow the error.

---

## Task 5: Run `bootstrap.py` end-to-end against the live hub

**Files:** none modified.

- [ ] **Step 1: Confirm `az` context is the child subscription**

```bash
az account show --query name -o tsv
```
Expected: `guardianlink-dev`. If not, `az account set --subscription WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER`.

- [ ] **Step 2: Run bootstrap**

```bash
cd apps/simulator && source .venv/bin/activate
python bootstrap.py
```

Expected output (first run):
```
bootstrapping simulator against iot-guardianlink-dev-weu
creating device 'sim-01'
wrote /.../apps/simulator/.env
bootstrap complete
```

Second run (idempotency check):
```bash
python bootstrap.py
```
Expected:
```
bootstrapping simulator against iot-guardianlink-dev-weu
device 'sim-01' already exists
wrote /.../apps/simulator/.env
bootstrap complete
```

- [ ] **Step 3: Verify `.env` contents and registry state**

```bash
grep -E '^(DEVICE_ID|TELEMETRY_PERIOD_S|CRASH_PERIOD_S)' .env
```
Expected:
```
DEVICE_ID=sim-01
TELEMETRY_PERIOD_S=20
CRASH_PERIOD_S=120
```

(Don't `cat` the full `.env` — the connection strings are secret. The non-secret lines are enough to confirm the write.)

Verify the device exists in the hub via `az`:
```bash
az iot hub device-identity show --hub-name iot-guardianlink-dev-weu --device-id sim-01 --query "{id:deviceId, status:status, authType:authentication.type}" -o table
```
Expected:
```
Id      Status    AuthType
------  --------  ----------
sim-01  enabled   sas
```

**Note:** this `az iot hub device-identity show` command also hits the iot-extension API-version bug that broke `az iot hub show` for the previous slice. If it fails with `API version ... does not have operation group 'resource_groups'`, fall back to ARM REST:
```bash
az rest --method GET --url "https://management.azure.com/subscriptions/WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER/resourceGroups/rg-guardianlink-dev/providers/Microsoft.Devices/IotHubs/iot-guardianlink-dev-weu/devices?api-version=2023-06-30" --query "value[?deviceId=='sim-01'].{id:deviceId, status:status, authType:authentication.type}" -o table
```

---

## Task 6: Build `simulator.py`

**Files:**
- Create: `apps/simulator/simulator.py`

- [ ] **Step 1: Write `simulator.py`**

```python
"""Async device simulator: pushes telemetry + crash-suspect messages
until Ctrl-C. Instruments sends as log records in App Insights `traces`.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
from datetime import datetime, timezone

from azure.iot.device import Message
from azure.iot.device.aio import IoTHubDeviceClient
from azure.monitor.opentelemetry import configure_azure_monitor
from dotenv import load_dotenv

from payload import build_crash_suspect, build_telemetry


log = logging.getLogger("simulator")


def _configure() -> dict:
    load_dotenv()
    required = [
        "IOTHUB_DEVICE_CONNECTION_STRING",
        "APPLICATIONINSIGHTS_CONNECTION_STRING",
        "DEVICE_ID",
    ]
    missing = [k for k in required if not os.environ.get(k)]
    if missing:
        raise SystemExit(f"missing env vars: {missing}. run bootstrap.py first.")
    configure_azure_monitor(
        connection_string=os.environ["APPLICATIONINSIGHTS_CONNECTION_STRING"],
    )
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    return {
        "device_id": os.environ["DEVICE_ID"],
        "telemetry_period_s": float(os.environ.get("TELEMETRY_PERIOD_S", "20")),
        "crash_period_s": float(os.environ.get("CRASH_PERIOD_S", "120")),
        "conn_str": os.environ["IOTHUB_DEVICE_CONNECTION_STRING"],
    }


def _make_message(body: dict, event_type: str) -> Message:
    msg = Message(json.dumps(body))
    msg.content_encoding = "utf-8"
    msg.content_type = "application/json"
    msg.custom_properties["eventType"] = event_type
    return msg


async def _send_loop(
    client: IoTHubDeviceClient,
    device_id: str,
    period_s: float,
    event_type: str,
    builder,
) -> None:
    while True:
        try:
            body = builder(device_id, datetime.now(timezone.utc))
            await client.send_message(_make_message(body, event_type))
            log.info(
                "message_sent",
                extra={"custom_dimensions": {"event_type": event_type, "device_id": device_id}},
            )
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001 - keep the loop alive on transient errors
            log.warning(
                "message_send_failed",
                extra={"custom_dimensions": {
                    "event_type": event_type, "device_id": device_id, "error": repr(e),
                }},
            )
        await asyncio.sleep(period_s)


async def _run() -> None:
    cfg = _configure()
    client = IoTHubDeviceClient.create_from_connection_string(cfg["conn_str"])

    async def on_connection_state_change():
        state = client.connected
        if state:
            log.info(
                "connection_restored",
                extra={"custom_dimensions": {"device_id": cfg["device_id"]}},
            )
        else:
            log.warning(
                "connection_lost",
                extra={"custom_dimensions": {"device_id": cfg["device_id"]}},
            )

    client.on_connection_state_change = on_connection_state_change

    await client.connect()
    log.info(
        "connection_restored",
        extra={"custom_dimensions": {"device_id": cfg["device_id"]}},
    )

    telemetry_task = asyncio.create_task(
        _send_loop(client, cfg["device_id"], cfg["telemetry_period_s"], "telemetry", build_telemetry)
    )
    crash_task = asyncio.create_task(
        _send_loop(client, cfg["device_id"], cfg["crash_period_s"], "crash_suspect", build_crash_suspect)
    )

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_event.set)

    await stop_event.wait()
    log.info("shutting down")

    telemetry_task.cancel()
    crash_task.cancel()
    for t in (telemetry_task, crash_task):
        try:
            await t
        except asyncio.CancelledError:
            pass

    await client.shutdown()


def main() -> None:
    asyncio.run(_run())


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Import-sanity check** (no network)

```bash
python -c "import simulator; print('ok')"
```
Expected: `ok`.

*Implementation note for reviewers:* the `azure-iot-device` async client's connection-state callback is typically set via the `on_connection_state_change` attribute. If the installed SDK version rejects this (API has shifted across 2.x minors), set it via `client.on_connection_state_change = callback` with a synchronous callback, or fall through and skip the callback binding — the connect-then-log-once pattern still covers the common case. Prefer to make it work; log a clear warning if the SDK refuses the binding and proceed without connection-state events.

---

## Task 7: End-to-end run + verification

**Files:** none modified.

- [ ] **Step 1: Run the simulator for ~2 minutes**

```bash
cd apps/simulator && source .venv/bin/activate
python simulator.py
```

Let it run for ~2 minutes while observing stdout. Expected stdout shape (interleaved):
```
2026-04-24 ... INFO simulator: connection_restored
2026-04-24 ... INFO simulator: message_sent
2026-04-24 ... INFO simulator: message_sent
...
2026-04-24 ... INFO simulator: message_sent   # the crash message, also logged as message_sent
```

(Both telemetry and crash messages log as `message_sent`; they are distinguished by the `event_type` dimension, not the log message text.)

After ~2 minutes there should be ~6 telemetry sends + 1 crash send = ~7 `message_sent` log lines.

- [ ] **Step 2: Ctrl-C to stop; confirm clean shutdown**

Press Ctrl-C. Expected tail of stdout:
```
2026-04-24 ... INFO simulator: shutting down
```
No tracebacks. If the process hangs on shutdown, escalate — don't paper over it.

- [ ] **Step 3: Verify in the portal (IoT Hub metrics)**

Portal → `iot-guardianlink-dev-weu` → Metrics → add metric "Total number of messages used" (sum, last 30 min). Expected: ≥ 6.

- [ ] **Step 4: Verify in the portal (Event Hub data explorer)**

Portal → `evhns-guardianlink-dev-weu` → Event Hubs → `telemetry` → Data Explorer → "View events". Expected: recent events listed; selecting one shows the JSON body and a `Properties → eventType` of `telemetry` or `crash_suspect`.

- [ ] **Step 5: Verify in App Insights (Logs)**

Portal → `appi-guardianlink-dev-weu` → Logs. Run:
```kusto
traces
| where timestamp > ago(15m)
| where message == "message_sent"
| summarize count() by tostring(customDimensions.event_type)
```
Expected: two rows, `telemetry` with the larger count, `crash_suspect` with 1 or 2. If the query returns zero rows, the AI connection string in `.env` is wrong or `configure_azure_monitor` didn't wire up — investigate before claiming success.

Allow up to 2–3 minutes for AI ingestion latency after stopping the simulator.

- [ ] **Step 6: Verify in Log Analytics (device connection events)**

Portal → `log-guardianlink-dev-weu` → Logs. Run:
```kusto
AzureDiagnostics
| where TimeGenerated > ago(15m)
| where ResourceType == "IOTHUBS" and Category == "Connections"
| project TimeGenerated, OperationName, Level
| order by TimeGenerated desc
| take 10
```
Expected: `deviceConnect` / `deviceDisconnect` rows from the simulator run. The `Routes` and `DeviceTelemetry` categories are **error-only** (they log route / pipeline failures, not successful deliveries); a healthy run produces zero rows there, which is correct.

If any of the four verification checks fail, **stop** and diagnose before proceeding to commit. The whole point of this slice is that these checks pass.

---

## Task 8: Commit spec + plan + simulator code together

**Files staged:**
- `docs/superpowers/specs/2026-04-24-simulator-slice-design.md`
- `docs/superpowers/plans/2026-04-24-simulator-slice.md`
- `apps/simulator/bootstrap.py`
- `apps/simulator/simulator.py`
- `apps/simulator/payload.py`
- `apps/simulator/tests/__init__.py`
- `apps/simulator/tests/test_payload.py`
- `apps/simulator/requirements.txt`
- `apps/simulator/requirements-dev.txt`
- `apps/simulator/.env.example`
- `apps/simulator/README.md`
- `.gitignore` (modification)

Per project preference, spec + plan + implementation land in one commit.

- [ ] **Step 1: Stage exactly the expected files**

From repo root:
```bash
git add \
  .gitignore \
  docs/superpowers/specs/2026-04-24-simulator-slice-design.md \
  docs/superpowers/plans/2026-04-24-simulator-slice.md \
  apps/simulator/bootstrap.py \
  apps/simulator/simulator.py \
  apps/simulator/payload.py \
  apps/simulator/tests/__init__.py \
  apps/simulator/tests/test_payload.py \
  apps/simulator/requirements.txt \
  apps/simulator/requirements-dev.txt \
  apps/simulator/.env.example \
  apps/simulator/README.md
```

- [ ] **Step 2: Verify staged set**

```bash
git status --short
```
Expected:
- One `M ` line for `.gitignore`
- Eleven `A ` lines for the new files above.
- **Nothing else staged.** In particular, `apps/simulator/.env` and `apps/simulator/.venv/` must not appear (gitignore handles them). If either does, fix the gitignore before committing.

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
add device simulator (sim-01) pushing telemetry + crash-suspect events

apps/simulator/: first non-Terraform slice. Python async client that
registers sim-01 as a SAS-provisioned device in the iot-guardianlink-dev-weu
IoT Hub and pushes telemetry (~1/20s) + crash-suspect (~1/120s) events
until Ctrl-C. Messages carry an 'eventType' custom property so the future
classifier can discriminate downstream.

bootstrap.py shells out to 'az iot hub connection-string show' for the
iothubowner SAS + 'az monitor app-insights component show' for the AI
connection string -- avoids the IoT Hub data-plane RBAC grant that isn't
inherited from subscription Owner. Idempotent across terraform
destroy/apply cycles.

payload.py is pure-function with unit tests under pytest (~300 parametrized
passes). Simulator loop uses azure-iot-device async + azure-monitor-
opentelemetry; sends + connection state changes log to App Insights
'traces' with custom dimensions.

Default rates keep F1 IoT Hub cap usage at ~37% margin for a 24h run.

Out of scope: fleet, X.509 device auth, DPS, Container App packaging,
integration tests against IoT Hub.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify working tree is clean**

```bash
git status --short
```
Expected: empty (or only `apps/simulator/.env` and `apps/simulator/.venv/` listed, which is fine — they're untracked and gitignored; they won't appear in `git status --short` at all if gitignore is correct).

---

## Done criteria

- `python -m pytest` passes in `apps/simulator/` with all tests green.
- `python bootstrap.py` completed successfully at least twice (second run is idempotent).
- `python simulator.py` ran ≥ 2 minutes without errors and Ctrl-C'd cleanly.
- All four verification checks in Task 7 returned expected results.
- One commit contains spec + plan + code.

## Update persistent state after completion

After Task 8 succeeds, update the project-state memory at
`/home/eyal/.claude/projects/-home-eyal-repos-guardian-link/memory/project-state.md`:
- Add a line noting the simulator is built + first non-TF component.
- Bump the commit SHA reference.
- Refresh the "next slice candidates" list to remove simulator and surface obvious follow-ons (Storage + telemetry-writer Function, Key Vault, Service Bus, consumer groups + RBAC on the Event Hub).
