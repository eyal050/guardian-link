# GuardianLink device simulator

Local Python process(es) that connect to the `iot-guardianlink-dev-weu`
IoT Hub as SAS-provisioned devices and push telemetry +
crash-suspect events until Ctrl-C.

One process represents one physical device. The roster of devices
lives in `devices.json`; `bootstrap.py` registers each one and writes
a per-device `.env.<id>` file consumed by `simulator.py --device <id>`.

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
python bootstrap.py               # registers every device in devices.json, writes .env.<id> per device
```

`bootstrap.py` is idempotent. Re-run it any time `devices.json`
changes or the IoT Hub is recreated (a `terraform destroy`/`apply`
cycle resets the device registry).

## Adding a device

Append an entry to `devices.json`:

```json
{
  "id": "sim-03",
  "telemetry_period_s": 33,
  "crash_period_s": 80
}
```

Re-run `python bootstrap.py`. It will register `sim-03` and emit
`.env.sim-03`. Existing devices are left untouched.

## Running

One terminal per device. They are independent processes.

```bash
source .venv/bin/activate
python simulator.py --device sim-01
# Ctrl-C to stop; disconnects cleanly.
```

```bash
source .venv/bin/activate
python simulator.py --device sim-02
```

`--device` is required and must match an `id` in `devices.json`.
The simulator loads `.env.<id>` from the same directory.

## Configuration

Per-device runtime tuning lives in `devices.json` (re-bootstrap to
propagate changes into `.env.<id>`):

- `telemetry_period_s` - seconds between telemetry messages.
- `crash_period_s` - seconds between crash-suspect messages.

**IoT Hub F1 cap:** 8000 messages/day, summed across **all** devices
on the hub. Two devices on the defaults (~5040 + ~3920 ≈ 8960/day)
will burn the cap; either trim the periods up or stop one of them
when not actively demoing.

## Verification

After running ~2 minutes (one or both devices), verify in the child
subscription:

1. Portal -> IoT Hub -> Metrics -> "Total number of messages used"
   trending upward.
2. Portal -> Event Hub `telemetry` -> Data Explorer -> messages
   visible with `eventType` property `telemetry` or `crash_suspect`.
3. App Insights Logs:
   ```
   traces | where message == "message_sent"
     | summarize count() by tostring(customDimensions.device_id),
                            tostring(customDimensions.event_type)
   ```
   Each running device id appears with its own row counts.
4. LAW Logs:
   ```
   AzureDiagnostics
   | where ResourceType == "IOTHUBS" and Category == "Connections"
   | project TimeGenerated, OperationName, Level
   | order by TimeGenerated desc
   | take 10
   ```
   `deviceConnect` / `deviceDisconnect` rows for the simulator runs.
   Note: the `Routes` and `DeviceTelemetry` categories are error-only;
   a healthy run produces zero rows there.
