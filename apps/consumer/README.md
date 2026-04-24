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
- `STARTING_POSITION` - `@latest` (new events only, default) or `-1`
  (also "end of stream"). Use `"-1"` in SDK-speak if `@latest` is
  not recognized by the installed azure-eventhub version.

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
