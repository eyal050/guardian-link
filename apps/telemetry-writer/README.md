# GuardianLink telemetry-writer Function

Event-Hub-triggered Python Function App that consumes from the
`telemetry` hub and (eventually) writes raw events to Blob + hot rows
to Cosmos.

**Slice α+** the function logs each event to App Insights *and* upserts
it into the Cosmos `telemetry` container as a JSON document. Blob raw-
archive write is a future slice.

The infrastructure (App Service plan, Function App, identity-based EH
connection, `Azure Event Hubs Data Receiver` role grant, FunctionAppLogs
diagnostics, and the dedicated `telemetry-writer` consumer group) is in
`terraform/guardianlink-dev/functions.tf`.

## Why a Function and not a Container App

Architecture decision: the telemetry-writer is a Function App, not a
Container App. The Functions Event Hubs trigger handles partition
assignment and checkpointing in its own internal `AzureWebJobsStorage`,
so the durable writer doesn't reuse the `eh-checkpoints` blob container
that `apps/consumer/` uses — that container exists only to support the
local debug consumer's `BlobCheckpointStore`. Two different consumer-
group strategies, deliberately. See `docs/architecture.md` decision #8.

## Prerequisites

- Azure Functions Core Tools v4 (`func --version` should report `4.x`).
  Install per Microsoft docs: search "install Azure Functions Core Tools".
- Azure CLI logged in against the `guardianlink-dev` subscription:
  `az account show` should return `name: guardianlink-dev`.
- Python 3.10 in the toolchain (`python --version`). The plan is
  configured for 3.10; deploying a wheel built against a different minor
  lands in a runtime that doesn't have it.
- The Terraform stack applied (`func-…-telemetry-writer` must exist).

## Local setup

```bash
cd apps/telemetry-writer
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
python -m pytest                  # should pass before deploying
```

## Deploy

The function depends on `azure-cosmos` and `azure-identity`, which are
NOT in the Linux Consumption Python worker base image. URL-based
`WEBSITE_RUN_FROM_PACKAGE` deploys skip the Oryx remote build, so deps
must be bundled into the zip under `.python_packages/lib/site-packages/`
— that path is auto-added to `sys.path` by the worker.

The pip flags below are not optional. The Linux Consumption Python 3.10
runtime image ships **glibc 2.31**. Modern build hosts (Ubuntu 22.04 /
WSL2 → glibc 2.35+) cause pip to pick the newest manylinux wheel for
transitive deps like `cryptography` — `cryptography>=43` publishes a
`manylinux_2_34` wheel whose `_rust.abi3.so` needs `GLIBC_2.33`. Drop
that into the runtime and the worker fails to import the binding,
"No job functions found" gets logged at host startup, and the trigger
silently never fires. Pinning `--platform manylinux2014_x86_64`
(glibc 2.17) forces pip to download a wheel the runtime can actually
load. `--only-binary=:all:` makes pip fail loudly if no compatible
prebuilt wheel exists for any dep, instead of falling back to a
local source build that would re-introduce the host-glibc problem.

```bash
source .venv/bin/activate
rm -rf .python_packages /tmp/telemetry-writer.zip
pip install \
  --target=".python_packages/lib/site-packages" \
  --platform manylinux2014_x86_64 \
  --implementation cp --python-version 3.10 \
  --only-binary=:all: \
  -r requirements.txt
python -c "
import zipfile, pathlib
z = pathlib.Path('/tmp/telemetry-writer.zip')
with zipfile.ZipFile(z, 'w', zipfile.ZIP_DEFLATED) as zf:
    for f in ('function_app.py', 'host.json', 'requirements.txt'):
        zf.write(f)
    for p in pathlib.Path('.python_packages').rglob('*'):
        if p.is_file():
            zf.write(p)
"
az functionapp deployment source config-zip \
  -g rg-guardianlink-dev \
  -n func-guardianlink-dev-weu-telemetry-writer \
  --src /tmp/telemetry-writer.zip
```

Sanity check before uploading: the bundled cryptography wheel should be
manylinux_2_17, not _2_34:

```bash
cat .python_packages/lib/site-packages/cryptography-*.dist-info/WHEEL \
  | grep '^Tag:'
# Expected: cp38-abi3-manylinux_2_17_x86_64 (and manylinux2014 alias)
```

If `func` Azure Functions Core Tools were installed, `func azure
functionapp publish ... --python` is the friendlier path (it runs a
remote Oryx build, sidestepping the glibc-mismatch problem entirely),
but it requires Microsoft package repo setup + sudo on Debian/Ubuntu.

## Verify

1. Run the simulator in a second terminal:
   ```bash
   cd ../simulator && python simulator.py --device sim-01
   ```
2. In App Insights → Logs (allow ~30-60s after first apply for RBAC
   propagation; until then expect 401/403 in `FunctionAppLogs`):
   ```kusto
   traces
   | where timestamp > ago(10m)
   | where cloud_RoleName == "func-guardianlink-dev-weu-telemetry-writer"
   | where message == "event_received"
   | project timestamp,
             device_id   = tostring(customDimensions.device_id),
             event_type  = tostring(customDimensions.event_type),
             offset      = tostring(customDimensions.offset)
   | take 20
   ```
   Expected: one row per simulator message with `event_type` =
   `telemetry` or `crash_suspect` and `device_id` populated.

3. Cross-check checkpoint isolation: the writer's checkpoints land in
   the AzureWebJobsStorage account (`stgl*`) under blob container
   `azure-webjobs-eventhub`. The `apps/consumer/` debug consumer's
   checkpoints continue to live under `eh-checkpoints` — they are NOT
   shared. Two separate consumer groups, two separate stores.
4. Cosmos write check: query the container directly with the Azure
   CLI (the signed-in user needs the `Cosmos DB Built-in Data Reader`
   role on the account — granting it is a separate one-time step):
   ```bash
   az cosmosdb sql query --account-name cosmos-guardianlink-dev-weu \
     -g rg-guardianlink-dev -d guardianlink -c telemetry \
     --query-text 'SELECT VALUE COUNT(1) FROM c' \
     --partition-key-value sim-01 --auth-mode login
   ```
   Should return a positive count and grow over time. (As of writing,
   `az cosmosdb sql query` is preview — if it's flaky, KQL via LAW on
   `AppRequests` from the writer also reflects successful writes.)

## What's NOT in this slice

- Blob write of raw events (next slice).
- DLQ / poison-message handling beyond default trigger retry.
- Batch cardinality (currently single-event; `cardinality=many` is a
  follow-up perf slice).

## Troubleshooting

- **No `event_received` rows in App Insights.** Check `FunctionAppLogs`
  for trigger startup errors. Common causes: RBAC not yet propagated
  (wait 60s and retry); `EH_TELEMETRY__credential` typo; consumer group
  `telemetry-writer` not actually created on the hub.
- **`Host.Startup` warns "No job functions found" + `Host.Function.Console`
  errors with `ImportError: ... GLIBC_2.33 not found ...
  cryptography/hazmat/bindings/_rust.abi3.so`.** The bundled wheel was
  built for a newer glibc than the Functions runtime exposes. Re-run
  the pip install with the `--platform manylinux2014_x86_64
  --only-binary=:all:` flags shown in the Deploy section, rebuild the
  zip, redeploy. Verify with the `WHEEL` `grep` after the install.
- **Connection refused / 401 from EH.** Confirm
  `EH_TELEMETRY__fullyQualifiedNamespace` matches
  `<namespace>.servicebus.windows.net` (no `https://`, no trailing slash).
- **Function App boots but trigger never fires.** The host needs read
  access to the EH namespace's metadata too in some scenarios. If
  symptoms point that way, broaden the role scope from the hub to the
  namespace temporarily and narrow back once it works.
