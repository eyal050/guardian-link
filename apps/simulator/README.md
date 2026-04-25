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
source .venv/bin/activate
python simulator.py
# Ctrl-C to stop; disconnects cleanly.
```

## Configuration

Tune via `.env`:
- `TELEMETRY_PERIOD_S` - seconds between telemetry messages (default 20).
- `CRASH_PERIOD_S` - seconds between crash-suspect messages (default 120).

**IoT Hub F1 cap:** 8000 messages/day. Defaults produce ~5040/day
(37% margin). Dropping periods below ~15s will burn the cap within
a workday. The hub silently 429s when the cap is hit.

## Verification

After running ~2 minutes, verify in the child subscription:

1. Portal -> IoT Hub -> Metrics -> "Total number of messages used" >= 6.
2. Portal -> Event Hub `telemetry` -> Data Explorer -> messages visible
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
   | where ResourceType == "IOTHUBS" and Category == "Connections"
   | project TimeGenerated, OperationName, Level
   | order by TimeGenerated desc
   | take 10
   ```
   `deviceConnect` / `deviceDisconnect` rows for the simulator run. Note: the `Routes` and `DeviceTelemetry` categories are error-only; a healthy run produces zero rows there.
