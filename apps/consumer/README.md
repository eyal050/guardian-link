# GuardianLink Event Hub inspector consumer

Local Python process that reads events from the `telemetry` Event Hub
via the `inspector` consumer group using Entra ID auth, formats each
message to stdout, and logs to App Insights.

This is a demo-focused observer, not the production telemetry-writer.
It does not write messages anywhere besides stdout + App Insights.

It checkpoints partition offsets to a Blob container so multiple
instances in the same consumer group cooperate on partition ownership
(load balance) instead of each draining all partitions independently.

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
python bootstrap.py               # grants Data Receiver + Blob Data Contributor, writes .env
```

After a fresh role grant, Azure RBAC may take 30-60s to propagate. If
the first `consumer.py` run 403s on Event Hub or Blob, wait a minute
and retry.

## Running

```bash
source .venv/bin/activate
python consumer.py
# Ctrl-C to stop; closes the client cleanly.
```

Run the simulator (`apps/simulator/python simulator.py --device sim-01`) in a
second terminal. Messages from the simulator land in the consumer's stdout.

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
3. Checkpoint blobs appear under
   `<storage-account>/eh-checkpoints/<eh-fqdn>/telemetry/inspector/checkpoint/<partition>`.
   Quick check: `az storage blob list --account-name <st> -c eh-checkpoints --auth-mode login -o table`.

## Load-balanced run (two consumers)

Start two `python consumer.py` processes in separate terminals against
the same `.env`. The SDK's load balancer (backed by the checkpoint
container) splits the 4 partitions roughly 2/2 between them. Each
event prints in exactly one consumer's stdout, not both. Killing one
process triggers a rebalance: the survivor picks up the orphaned
partitions within ~30s.
