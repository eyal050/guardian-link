# Event Hub inspector consumer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `inspector` consumer group to the `telemetry` Event Hub, plus a local Python consumer app (`apps/consumer/`) that reads events from it using Entra ID auth and logs them to stdout + App Insights. Running the simulator + consumer side-by-side demonstrates end-to-end message flow through Azure.

**Architecture:** Tiny TF change (one `azurerm_eventhub_consumer_group` resource appended to `eventhubs.tf`) + a Python app mirroring the `apps/simulator/` layout: `bootstrap.py` (idempotent role grant + .env write via `az` subprocess), `consumer.py` (async `EventHubConsumerClient` using `DefaultAzureCredential`), `format.py` (pure string formatter, unit-tested). App Insights instrumentation via `azure-monitor-opentelemetry` with the ordering and dim-shape lessons from the simulator slice already baked in. Spec: `docs/superpowers/specs/2026-04-24-consumer-slice-design.md`.

**Tech Stack:** Terraform (azurerm 4.69), Python 3.10+, pytest, `azure-eventhub`, `azure-identity`, `azure-monitor-opentelemetry`, `python-dotenv`. Azure CLI as runtime prerequisite of `bootstrap.py`.

**Depends on existing infra (commit `879a48e`):**
- Event Hubs namespace `evhns-guardianlink-dev-weu`, hub `telemetry` (4 partitions, 7-day retention, `local_authentication_enabled = false`).
- App Insights `appi-guardianlink-dev-weu`.
- LAW `log-guardianlink-dev-weu`.
- IoT Hub + route + simulator producing messages.

**Local prerequisites:** `az login` against the `guardianlink-dev` child subscription, Python 3.10+.

**Testing approach:** pytest against `format.py`. No integration tests against Event Hubs. E2E validated manually by running the simulator + consumer and observing stdout + App Insights.

**Lessons pre-applied from prior slices** (do not re-derive):
- `logging.basicConfig(...)` MUST run BEFORE `configure_azure_monitor(...)`. Reversed order silences stderr.
- `extra={<key>: <value>, ...}` directly — do NOT nest under `custom_dimensions`. The OTel distro stringifies nested dicts; `customDimensions.event_type` queries return empty strings otherwise.
- IoT Hub's `az iot` extension is broken on this machine; ARM REST or `az role assignment` are fine. No `az iot` calls appear in this plan.

---

## File Structure

- **Create** (TF): nothing new; append one block to `terraform/guardianlink-dev/eventhubs.tf`.
- **Create** (Python):
  - `apps/consumer/bootstrap.py`
  - `apps/consumer/consumer.py`
  - `apps/consumer/format.py`
  - `apps/consumer/tests/__init__.py`
  - `apps/consumer/tests/test_format.py`
  - `apps/consumer/requirements.txt`
  - `apps/consumer/requirements-dev.txt`
  - `apps/consumer/.env.example`
  - `apps/consumer/README.md`
- **Modify:** `terraform/guardianlink-dev/eventhubs.tf` (append only).

---

## Task 1: Add the `inspector` consumer group in Terraform

**Files:**
- Modify: `terraform/guardianlink-dev/eventhubs.tf` (append)

- [ ] **Step 1: Append the consumer-group resource**

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

- [ ] **Step 2: Format and validate**

From `terraform/guardianlink-dev/`:
```bash
terraform fmt
./run.sh validate
```
Expected: `fmt` silent; `validate` prints `Success! The configuration is valid` (plus the pre-existing `metric` deprecation warnings — unrelated).

- [ ] **Step 3: Plan and inspect**

```bash
./run.sh plan
```
Expected: `Plan: 1 to add, 0 to change, 0 to destroy.` The one addition is `azurerm_eventhub_consumer_group.inspector` with:
- `name = "inspector"`
- `namespace_name = "evhns-guardianlink-dev-weu"`
- `eventhub_name = "telemetry"`
- `resource_group_name = "rg-guardianlink-dev"`

If plan reports any change besides that single add, STOP and investigate.

- [ ] **Step 4: Apply**

```bash
./run.sh apply -auto-approve
```
Expected: `Apply complete! Resources: 1 added, 0 changed, 0 destroyed.` Consumer groups create in seconds (no provisioning latency like a namespace).

- [ ] **Step 5: Confirm no drift**

```bash
./run.sh plan
```
Expected: `No changes. Your infrastructure matches the configuration.`

- [ ] **Step 6: Verify via az**

```bash
az eventhubs eventhub consumer-group list \
  -g "rg-guardianlink-dev" --namespace-name "evhns-guardianlink-dev-weu" \
  --eventhub-name "telemetry" --query "[].name" -o tsv
```
Expected output contains both `$Default` and `inspector`.

---

## Task 2: Scaffold `apps/consumer/` directory

**Files:**
- Create: `apps/consumer/requirements.txt`, `apps/consumer/requirements-dev.txt`, `apps/consumer/.env.example`, `apps/consumer/README.md`, `apps/consumer/tests/__init__.py`

- [ ] **Step 1: Create `apps/consumer/requirements.txt`**

```
azure-eventhub>=5.12
azure-identity>=1.19
azure-monitor-opentelemetry>=1.6
python-dotenv>=1.0
```

- [ ] **Step 2: Create `apps/consumer/requirements-dev.txt`**

```
-r requirements.txt
pytest>=8
ruff>=0.6
```

- [ ] **Step 3: Create `apps/consumer/.env.example`**

```
# Populated by bootstrap.py; this template is committed for reference.
EVENT_HUB_FQDN=evhns-guardianlink-dev-weu.servicebus.windows.net
EVENT_HUB_NAME=telemetry
CONSUMER_GROUP=inspector
STARTING_POSITION=@latest
APPLICATIONINSIGHTS_CONNECTION_STRING=InstrumentationKey=<key>;IngestionEndpoint=https://<region>.in.applicationinsights.azure.com/
```

- [ ] **Step 4: Create empty `apps/consumer/tests/__init__.py`**

- [ ] **Step 5: Create `apps/consumer/README.md`**

```markdown
# GuardianLink Event Hub inspector consumer

Local Python process that reads events from the `telemetry` Event Hub
via the `inspector` consumer group using Entra ID auth, formats each
message to stdout, and logs to App Insights.

This is a demo-focused observer, not the production telemetry-writer.
It does not checkpoint and does not write messages anywhere.

## Prerequisites

- Python 3.10+
- Azure CLI logged in against the `guardianlink-dev` subscription:
  `az account show` should return `name: guardianlink-dev`.
- The `guardianlink-dev` Terraform stack applied (`inspector` consumer
  group must exist on the `telemetry` hub).

## One-time setup

```bash
cd apps/consumer
python -m venv .venv && source .venv/bin/activate
# If `python -m venv` fails (missing python3-venv on Debian/Ubuntu),
# the project uses virtualenv instead:
#   pip install --user virtualenv && virtualenv .venv
pip install -r requirements-dev.txt
python -m pytest                  # should pass before running anything live
python bootstrap.py               # grants Data Receiver role, writes .env
```

After a fresh role grant, Azure RBAC may take 30-60s to propagate. If
the first `consumer.py` run 403s, wait a minute and retry.

## Running

```bash
python consumer.py
# Ctrl-C to stop; closes the client cleanly.
```

Run the simulator (`apps/simulator/python simulator.py`) in a second
terminal. Messages from the simulator land in the consumer's stdout.

## Configuration

Tune via `.env`:
- `STARTING_POSITION` - `@latest` (new events only, default) or `@earliest`
  (entire hub retention window).

## Verification

With simulator + consumer running:

1. Consumer stdout shows one formatted line per simulator message,
   with `eventType=telemetry` or `eventType=crash_suspect`.
2. App Insights Logs:
   ```
   traces | where message == "message_received"
     | summarize count() by tostring(customDimensions.event_type)
   ```
   Counts mirror the simulator's `message_sent` rows (with small delay).
```

- [ ] **Step 6: Verify directory structure**

```bash
find apps/consumer -type f | sort
```
Expected:
```
apps/consumer/.env.example
apps/consumer/README.md
apps/consumer/requirements-dev.txt
apps/consumer/requirements.txt
apps/consumer/tests/__init__.py
```

---

## Task 3: Create venv + install dependencies

**Files:** none modified.

- [ ] **Step 1: Create venv and install**

```bash
cd apps/consumer
# Prefer `python -m venv`; this machine's system Python is missing
# python3-venv, so virtualenv is the fallback (matches simulator setup).
virtualenv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements-dev.txt
```
Expected: pip completes without errors.

- [ ] **Step 2: Sanity check imports**

```bash
python -c "import azure.eventhub, azure.identity, azure.monitor.opentelemetry, dotenv; print('ok')"
pytest --version
```
Expected: `ok` + a pytest version string. If imports fail, investigate before writing code.

---

## Task 4: Build `format.py` via TDD

**Files:**
- Create: `apps/consumer/format.py`
- Create: `apps/consumer/tests/test_format.py`

All steps from `apps/consumer/` with the venv activated.

- [ ] **Step 1: Write failing tests**

Create `apps/consumer/tests/test_format.py`:

```python
from datetime import datetime, timezone

from format import format_event


T = datetime(2026, 4, 24, 19, 49, 13, tzinfo=timezone.utc)


def _telemetry_body() -> dict:
    return {
        "device_id": "sim-01",
        "timestamp": T.isoformat(),
        "accelerometer": {"x": 0.12, "y": -0.05, "z": 0.98},
        "gps": {"lat": 52.3676, "lon": 4.9041},
        "battery_pct": 87.2,
        "heart_rate_bpm": 73,
        "suspect_confidence": None,
    }


def _crash_body() -> dict:
    return {
        "device_id": "sim-01",
        "timestamp": T.isoformat(),
        "accelerometer": {"x": 0.1, "y": 8.2, "z": -0.3},
        "gps": {"lat": 52.3676, "lon": 4.9041},
        "battery_pct": 80.0,
        "heart_rate_bpm": 150,
        "suspect_confidence": 0.65,
    }


def test_telemetry_format_includes_core_fields():
    s = format_event(_telemetry_body(), "telemetry", "2", T)
    assert "telemetry" in s
    assert "sim-01" in s
    assert "p=2" in s
    assert "HR=73" in s
    assert "bat=87.2" in s
    assert "accel=(0.12,-0.05,0.98)" in s
    # Confidence must NOT appear for plain telemetry
    assert "conf=" not in s


def test_crash_suspect_includes_confidence():
    s = format_event(_crash_body(), "crash_suspect", "1", T)
    assert "crash_suspect" in s
    assert "conf=0.65" in s
    assert "HR=150" in s


def test_missing_fields_tolerated():
    # An empty body must not raise; placeholders are used instead.
    s = format_event({}, "", "0", T)
    assert "p=0" in s
    # Do not assert specifics beyond "doesn't crash"


def test_enqueued_time_iso_formatted():
    s = format_event(_telemetry_body(), "telemetry", "0", T)
    # The enqueued time should appear in ISO-8601; we accept either the
    # full microsecond form or second-only truncation.
    assert "2026-04-24T19:49:13" in s
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
python -m pytest -q
```
Expected: collection error (`ModuleNotFoundError: No module named 'format'`).

- [ ] **Step 3: Implement `format.py`**

Create `apps/consumer/format.py`:

```python
"""Pure function: turn an Event Hub event into a human-readable line."""

from __future__ import annotations

from datetime import datetime


def _fmt_accel(accel: dict | None) -> str:
    if not accel:
        return "?"
    x = accel.get("x", "?")
    y = accel.get("y", "?")
    z = accel.get("z", "?")
    return f"({x},{y},{z})"


def format_event(
    body: dict,
    event_type: str,
    partition_id: str,
    enqueued_time: datetime,
) -> str:
    device_id = body.get("device_id", "?")
    hr = body.get("heart_rate_bpm", "?")
    battery = body.get("battery_pct", "?")
    accel = _fmt_accel(body.get("accelerometer"))
    conf = body.get("suspect_confidence")
    ts = enqueued_time.isoformat() if enqueued_time is not None else "?"

    # Build the trailing metrics segment so crash variants include confidence.
    tail = f"HR={hr} bat={battery} accel={accel}"
    if conf is not None:
        tail = f"conf={conf} " + tail

    return f"[p={partition_id} {event_type} {device_id} @ {ts}] {tail}"
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
python -m pytest -q
```
Expected: 4 passed.

---

## Task 5: Build `bootstrap.py`

**Files:**
- Create: `apps/consumer/bootstrap.py`

- [ ] **Step 1: Write `bootstrap.py`**

```python
"""Idempotent bootstrap: grant the current az-logged-in user the
'Azure Event Hubs Data Receiver' role on the telemetry hub, then
persist the App Insights connection string + hub coordinates to .env.

Shells out to `az` so we inherit the user's existing `az login`.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


SUBSCRIPTION_ID = "WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER"
RESOURCE_GROUP = "rg-guardianlink-dev"
NAMESPACE = "evhns-guardianlink-dev-weu"
EVENT_HUB = "telemetry"
CONSUMER_GROUP = "inspector"
APPINSIGHTS_NAME = "appi-guardianlink-dev-weu"

HUB_SCOPE = (
    f"/subscriptions/{SUBSCRIPTION_ID}"
    f"/resourceGroups/{RESOURCE_GROUP}"
    f"/providers/Microsoft.EventHub"
    f"/namespaces/{NAMESPACE}"
    f"/eventhubs/{EVENT_HUB}"
)


def _az(args: list[str], *, allow_nonzero: bool = False) -> subprocess.CompletedProcess:
    """Run `az <args>`; by default, exit on nonzero."""
    result = subprocess.run(["az", *args], capture_output=True, text=True)
    if result.returncode != 0 and not allow_nonzero:
        print(f"az command failed: az {' '.join(args)}", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        sys.exit(1)
    return result


def get_current_principal_oid() -> str:
    out = _az(["ad", "signed-in-user", "show", "--query", "id", "-o", "tsv"]).stdout.strip()
    if not out:
        print("could not resolve signed-in user object ID", file=sys.stderr)
        sys.exit(1)
    return out


def grant_data_receiver(principal_oid: str) -> None:
    """Grant Data Receiver on the telemetry hub. Idempotent."""
    result = _az(
        [
            "role", "assignment", "create",
            "--role", "Azure Event Hubs Data Receiver",
            "--scope", HUB_SCOPE,
            "--assignee-object-id", principal_oid,
            "--assignee-principal-type", "User",
        ],
        allow_nonzero=True,
    )
    if result.returncode == 0:
        print(f"granted 'Azure Event Hubs Data Receiver' to {principal_oid}")
        return
    # Already-exists is fine; any other error is not.
    stderr = (result.stderr or "") + (result.stdout or "")
    if "RoleAssignmentExists" in stderr or "already exists" in stderr.lower():
        print(f"role already granted to {principal_oid}")
        return
    print(f"az role assignment create failed:\n{stderr}", file=sys.stderr)
    sys.exit(1)


def get_appinsights_conn() -> str:
    out = _az([
        "monitor", "app-insights", "component", "show",
        "-g", RESOURCE_GROUP,
        "--app", APPINSIGHTS_NAME,
        "--query", "connectionString", "-o", "tsv",
    ]).stdout.strip()
    if not out:
        print("empty app insights connection string", file=sys.stderr)
        sys.exit(1)
    return out


def write_env(ai_conn: str, env_path: Path) -> None:
    lines = [
        f"EVENT_HUB_FQDN={NAMESPACE}.servicebus.windows.net",
        f"EVENT_HUB_NAME={EVENT_HUB}",
        f"CONSUMER_GROUP={CONSUMER_GROUP}",
        "STARTING_POSITION=@latest",
        f"APPLICATIONINSIGHTS_CONNECTION_STRING={ai_conn}",
        "",
    ]
    env_path.write_text("\n".join(lines))
    print(f"wrote {env_path}")


def main() -> None:
    print(f"bootstrapping consumer for {NAMESPACE}/{EVENT_HUB} (cg={CONSUMER_GROUP})")
    oid = get_current_principal_oid()
    grant_data_receiver(oid)
    ai_conn = get_appinsights_conn()
    write_env(ai_conn, Path(__file__).parent / ".env")
    print("bootstrap complete")
    print("note: RBAC propagation can take 30-60s on a fresh grant")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Import-sanity check** (no Azure calls)

```bash
python -c "import bootstrap; print('ok')"
```
Expected: `ok`.

---

## Task 6: Run `bootstrap.py` end-to-end

**Files:** none modified.

- [ ] **Step 1: Confirm `az` context**

```bash
az account show --query name -o tsv
```
Expected: `guardianlink-dev`. If not, switch: `az account set --subscription WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER`.

- [ ] **Step 2: Run bootstrap**

```bash
cd apps/consumer && source .venv/bin/activate
python bootstrap.py
```

Expected first run:
```
bootstrapping consumer for evhns-guardianlink-dev-weu/telemetry (cg=inspector)
granted 'Azure Event Hubs Data Receiver' to <oid>
wrote /.../apps/consumer/.env
bootstrap complete
note: RBAC propagation can take 30-60s on a fresh grant
```

- [ ] **Step 3: Re-run for idempotency**

```bash
python bootstrap.py
```
Expected: `role already granted to <oid>`. Exit code 0. `.env` rewritten (safe).

- [ ] **Step 4: Verify `.env` contents (non-secret lines) and role assignment**

```bash
grep -E '^(EVENT_HUB_FQDN|EVENT_HUB_NAME|CONSUMER_GROUP|STARTING_POSITION)' .env
```
Expected:
```
EVENT_HUB_FQDN=evhns-guardianlink-dev-weu.servicebus.windows.net
EVENT_HUB_NAME=telemetry
CONSUMER_GROUP=inspector
STARTING_POSITION=@latest
```

```bash
OID=$(az ad signed-in-user show --query id -o tsv)
EH_ID=$(az eventhubs eventhub show -g rg-guardianlink-dev --namespace-name evhns-guardianlink-dev-weu -n telemetry --query id -o tsv)
az role assignment list --scope "$EH_ID" --assignee "$OID" \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table
```
Expected: one row with `Role = Azure Event Hubs Data Receiver` and a scope ending in `/eventhubs/telemetry`.

---

## Task 7: Build `consumer.py`

**Files:**
- Create: `apps/consumer/consumer.py`

- [ ] **Step 1: Write `consumer.py`**

```python
"""Async Event Hub consumer: reads from the 'inspector' consumer group,
formats each event to stdout, logs to App Insights 'traces'.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import signal

from azure.eventhub.aio import EventHubConsumerClient
from azure.identity.aio import DefaultAzureCredential
from azure.monitor.opentelemetry import configure_azure_monitor
from dotenv import load_dotenv

from format import format_event


log = logging.getLogger("consumer")


def _configure() -> dict:
    load_dotenv()
    required = [
        "EVENT_HUB_FQDN",
        "EVENT_HUB_NAME",
        "CONSUMER_GROUP",
        "APPLICATIONINSIGHTS_CONNECTION_STRING",
    ]
    missing = [k for k in required if not os.environ.get(k)]
    if missing:
        raise SystemExit(f"missing env vars: {missing}. run bootstrap.py first.")
    # basicConfig BEFORE configure_azure_monitor (same lesson as simulator).
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    configure_azure_monitor(
        connection_string=os.environ["APPLICATIONINSIGHTS_CONNECTION_STRING"],
    )
    return {
        "fqdn": os.environ["EVENT_HUB_FQDN"],
        "hub": os.environ["EVENT_HUB_NAME"],
        "cg": os.environ["CONSUMER_GROUP"],
        "starting": os.environ.get("STARTING_POSITION", "@latest"),
    }


async def _on_event(partition_context, event) -> None:
    try:
        raw = event.body_as_str()
        body = json.loads(raw) if raw else {}
        event_type_bytes = (event.properties or {}).get(b"eventType", b"")
        event_type = event_type_bytes.decode() if isinstance(event_type_bytes, bytes) else str(event_type_bytes)
        line = format_event(
            body=body,
            event_type=event_type,
            partition_id=partition_context.partition_id,
            enqueued_time=event.enqueued_time,
        )
        print(line, flush=True)
        log.info(
            "message_received",
            extra={
                "event_type": event_type,
                "partition_id": partition_context.partition_id,
                "device_id": body.get("device_id", ""),
            },
        )
    except Exception as e:  # noqa: BLE001 - keep the pump alive
        log.warning(
            "message_decode_failed",
            extra={
                "partition_id": partition_context.partition_id,
                "error": repr(e),
            },
        )


async def _run() -> None:
    cfg = _configure()
    credential = DefaultAzureCredential()
    client = EventHubConsumerClient(
        fully_qualified_namespace=cfg["fqdn"],
        eventhub_name=cfg["hub"],
        consumer_group=cfg["cg"],
        credential=credential,
    )
    log.info("consumer_started", extra={"consumer_group": cfg["cg"]})
    print(
        f"consuming from {cfg['fqdn']}/{cfg['hub']} (cg={cfg['cg']}, starting={cfg['starting']})",
        flush=True,
    )

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_event.set)

    receive_task = asyncio.create_task(
        client.receive(on_event=_on_event, starting_position=cfg["starting"])
    )
    await stop_event.wait()
    log.info("shutting down")

    receive_task.cancel()
    try:
        await receive_task
    except asyncio.CancelledError:
        pass
    await client.close()
    await credential.close()


def main() -> None:
    asyncio.run(_run())


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Import-sanity check**

```bash
python -c "import consumer; print('ok')"
```
Expected: `ok`.

---

## Task 8: End-to-end run + verification

**Files:** none modified.

This task requires both the simulator and this new consumer to run concurrently. The consumer starts first (its `@latest` position means it would miss events if started after the simulator).

- [ ] **Step 1: Wait for RBAC propagation if bootstrap was recent**

If bootstrap just ran and granted the role for the first time, wait ~60s before proceeding. If the role was already there on re-run, skip the wait.

- [ ] **Step 2: Start the consumer**

In terminal 1:
```bash
cd apps/consumer && source .venv/bin/activate
python consumer.py
```

Expected first line:
```
consuming from evhns-guardianlink-dev-weu.servicebus.windows.net/telemetry (cg=inspector, starting=@latest)
```

followed by an `INFO consumer: consumer_started` log line. No message output yet — the simulator hasn't started.

If you see a `ClientAuthenticationError` or `Unauthorized (401)`, it means RBAC hasn't propagated; Ctrl-C, wait 30–60s, retry. Do not change the code.

- [ ] **Step 3: Start the simulator in a second terminal**

In terminal 2:
```bash
cd apps/simulator && source .venv/bin/activate
python simulator.py
```

Expected: as the simulator logs `message_sent` in terminal 2, terminal 1's consumer prints a formatted line within a second or two. Example consumer output:
```
[p=1 telemetry sim-01 @ 2026-04-24T19:52:15.123456+00:00] HR=73 bat=87.2 accel=(0.12,-0.05,0.98)
```

Let both run for ~90 seconds — enough to see at least one `crash_suspect` line emerge among the `telemetry` lines.

- [ ] **Step 4: Confirm `eventType` distinction in consumer stdout**

Grepping the terminal 1 output should show:
- Multiple `telemetry` lines (e.g., 5+).
- At least one `crash_suspect` line with a `conf=0.xx` prefix on the metrics tail.

- [ ] **Step 5: Stop both with Ctrl-C**

Ctrl-C the simulator first, then the consumer. Both should print `shutting down` and exit cleanly without tracebacks.

If the consumer's `await client.close()` hangs, something's wrong with the client state; escalate rather than papering over.

- [ ] **Step 6: Verify in App Insights**

```bash
AI_ID="/subscriptions/WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER/resourceGroups/rg-guardianlink-dev/providers/Microsoft.Insights/components/appi-guardianlink-dev-weu"
az monitor app-insights query --ids "$AI_ID" --analytics-query \
  'traces | where timestamp > ago(10m) | where message == "message_received" | summarize count() by tostring(customDimensions.event_type)' \
  --query "tables[0].rows" -o json
```
Expected: rows showing `telemetry` (majority) and `crash_suspect` (1+). The `event_type` dimension must be populated (non-empty strings), confirming the flat-`extra` dim mechanism works — if `event_type` is empty, investigate the logging call in `consumer.py`.

Allow 2–3 minutes for App Insights ingestion latency.

---

## Task 9: Commit everything together

**Files staged:**
- `terraform/guardianlink-dev/eventhubs.tf` (modified)
- `docs/superpowers/specs/2026-04-24-consumer-slice-design.md`
- `docs/superpowers/plans/2026-04-24-consumer-slice.md`
- `apps/consumer/bootstrap.py`
- `apps/consumer/consumer.py`
- `apps/consumer/format.py`
- `apps/consumer/tests/__init__.py`
- `apps/consumer/tests/test_format.py`
- `apps/consumer/requirements.txt`
- `apps/consumer/requirements-dev.txt`
- `apps/consumer/.env.example`
- `apps/consumer/README.md`

- [ ] **Step 1: Stage the exact files**

From repo root:
```bash
git add \
  terraform/guardianlink-dev/eventhubs.tf \
  docs/superpowers/specs/2026-04-24-consumer-slice-design.md \
  docs/superpowers/plans/2026-04-24-consumer-slice.md \
  apps/consumer/bootstrap.py \
  apps/consumer/consumer.py \
  apps/consumer/format.py \
  apps/consumer/tests/__init__.py \
  apps/consumer/tests/test_format.py \
  apps/consumer/requirements.txt \
  apps/consumer/requirements-dev.txt \
  apps/consumer/.env.example \
  apps/consumer/README.md
```

- [ ] **Step 2: Verify staged set**

```bash
git status --short
```
Expected:
- One `M ` line for `terraform/guardianlink-dev/eventhubs.tf`.
- Ten `A ` lines for the new files above (spec + plan + 8 app files).
- Nothing else staged. In particular, `apps/consumer/.env` and `apps/consumer/.venv/` must not appear (handled by existing gitignore).

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
add Event Hub inspector consumer + inspector consumer group

Closes the loop on the ingest pipeline: the simulator produces, the
new apps/consumer/ reads. Running both concurrently round-trips
messages through Azure end-to-end.

Terraform: one new azurerm_eventhub_consumer_group 'inspector' on the
telemetry hub. Kept separate from any future telemetry-writer Function
CG so multiple consumers can coexist without partition conflicts.

apps/consumer/: Python async client using EventHubConsumerClient +
DefaultAzureCredential (Entra ID, matches the namespace's
local_authentication_enabled=false policy). bootstrap.py grants the
signed-in user 'Azure Event Hubs Data Receiver' on the hub via az
subprocess (idempotent), writes .env. consumer.py formats each event
and logs to App Insights 'traces' with flat customDimensions
(event_type, partition_id, device_id). format.py is a pure
formatter under pytest.

basicConfig runs before configure_azure_monitor so stderr stays alive
once the OTel handler attaches -- same lesson as the simulator slice.

No checkpointing; starts from @latest by default. Demo-focused
inspector, not the telemetry-writer (that's a later Function slice).

Out of scope: Blob writes, Cosmos writes, checkpointing, Function App
packaging, X.509 device auth.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify clean tree**

```bash
git status --short
```
Expected: empty (other than gitignored `.venv/` + `.env` which don't appear).

---

## Done criteria

- `./run.sh plan` in `terraform/guardianlink-dev/` reports no drift after apply.
- `az eventhubs eventhub consumer-group list` for the telemetry hub includes `inspector`.
- `python -m pytest` in `apps/consumer/` passes all 4 tests.
- `python bootstrap.py` is idempotent (second run prints `role already granted`).
- `python consumer.py` runs ≥ 1 minute alongside an active simulator and prints formatted message lines with `eventType` distinguishing telemetry vs crash_suspect.
- App Insights query returns `message_received` rows grouped by non-empty `event_type`.
- Commit contains spec + plan + TF + code.

## Update persistent state after completion

After Task 9 succeeds, update `/home/eyal/.claude/projects/-home-eyal-repos-guardian-link/memory/project-state.md`:
- Add the `inspector` consumer group to the Event Hub bullet.
- Add a new bullet for `apps/consumer/` (mirror the simulator bullet's shape).
- Update the "device-ingest path wired end-to-end" sentence to note that a consumer now reads the hub.
- Bump the commit SHA reference.
- Refresh the "next slice candidates" list.
