# GuardianLink crash-classifier Function

Event-Hub-triggered Python Function App that reads `crash_suspect` events
from the `telemetry` hub on the `crash-classifier` consumer group,
fetches the preceding telemetry window from Cosmos, calls the ML endpoint
(or a hardcoded stub when `ML_ENDPOINT_URL` is empty), and publishes
a `crash_confirmed` message to the `crash-confirmed` Service Bus queue
when confidence >= 90% (architecture decision #11).

## Deploy

Same glibc constraint as the telemetry-writer: bundle deps with
`manylinux2014_x86_64` so the wheel matches the runtime's glibc 2.31.

```bash
cd apps/crash-classifier
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt   # for tests
python -m pytest                      # must pass first

rm -rf .python_packages
pip install \
  --target=".python_packages/lib/site-packages" \
  --platform manylinux2014_x86_64 \
  --implementation cp --python-version 3.10 \
  --only-binary=:all: \
  -r requirements.txt

# Sanity-check the cryptography wheel tag (must be manylinux_2_17):
cat .python_packages/lib/site-packages/cryptography-*.dist-info/WHEEL | grep '^Tag:'

python3 -c "
import zipfile, pathlib
z = pathlib.Path('/tmp/crash-classifier.zip')
with zipfile.ZipFile(z, 'w', zipfile.ZIP_DEFLATED) as zf:
    for f in ('function_app.py', 'host.json', 'requirements.txt'):
        zf.write(f)
    for p in pathlib.Path('.python_packages').rglob('*'):
        if p.is_file():
            zf.write(p)
"

az functionapp deployment source config-zip \
  -g rg-guardianlink-dev \
  -n func-guardianlink-dev-weu-crash-classifier \
  --src /tmp/crash-classifier.zip
```

## Verify

1. Run the simulator so `crash_suspect` events flow into Event Hubs:
   ```bash
   cd ../simulator && python3 simulator.py --device sim-01
   ```

2. Check App Insights for classifier logs (allow 30-60s for RBAC propagation):
   ```kusto
   traces
   | where cloud_RoleName == "func-guardianlink-dev-weu-crash-classifier"
   | where timestamp > ago(10m)
   | project timestamp, message
   | order by timestamp desc
   ```
   Expect rows with `crash_confirmed_published` (confidence 0.95 from stub).

3. Check the Service Bus queue depth (should accumulate messages):
   ```bash
   az servicebus queue show \
     -g rg-guardianlink-dev \
     --namespace-name sbns-guardianlink-dev-weu \
     --name crash-confirmed \
     --query "countDetails.activeMessageCount"
   ```

## What's next

- **ML Container App stub** — swap the hardcoded `_call_ml` stub for a real
  HTTP call to a Container App. Set `ML_ENDPOINT_URL` app setting once the
  Container App is deployed.
- **Notifier Function** — reads `crash-confirmed` from Service Bus, looks up
  emergency contacts in Postgres, fans out to SMS/email/push.
