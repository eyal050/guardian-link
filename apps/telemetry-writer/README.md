# GuardianLink telemetry-writer Function

Event-Hub-triggered Python Function App that consumes from the
`telemetry` hub, upserts each event into Cosmos, and archives every
batch as NDJSON to a separate Blob storage account.

**Slice β** (current) the function:
- logs each event to App Insights,
- upserts each event into Cosmos `telemetry` (per-event, idempotent
  on `id = <partition>-<offset>`),
- writes every batch as one NDJSON block-blob to the `telemetry-raw`
  container on `stglraw…` (per-invocation, idempotent on a deterministic
  `events/year=…/month=…/.../p<part>-<startOff>-<endOff>.ndjson` name).

Trigger cardinality is `many` so a Functions invocation maps 1:1 to a
single archive blob. See architecture decision #10 for the choices
behind format/path/scope.

The infrastructure (App Service plan, Function App, identity-based EH
connection, `Azure Event Hubs Data Receiver` role grant, the dedicated
`telemetry-writer` consumer group, the `Cosmos DB Built-in Data
Contributor` role, the `Storage Blob Data Contributor` role on the
archive SA, and FunctionAppLogs diagnostics) is in
`terraform/guardianlink-dev/functions.tf`. The archive storage account
itself (`raw_archive`) lives in `storage.tf`.

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
   `az cosmosdb sql query` is preview — if the subcommand isn't
   recognized at all on your CLI, KQL via LAW on `AppRequests` from
   the writer also reflects successful writes.)
5. Blob archive check (slice β). The signed-in user needs `Storage
   Blob Data Reader` on the archive SA (`stglraw…`); grant it once
   manually, RBAC propagation is 30-60s.
   ```bash
   ARCHIVE_SA=$(az storage account list -g rg-guardianlink-dev \
     --query "[?starts_with(name, 'stglraw')].name | [0]" -o tsv)
   az storage blob list --account-name "$ARCHIVE_SA" \
     --container-name telemetry-raw --auth-mode login \
     --prefix "events/year=$(date -u +%Y)/month=$(date -u +%m)/" \
     --query "[].{name:name, size:properties.contentLength}" -o table
   ```
   Expected: one blob per writer invocation under the current hour
   bucket, with non-zero size. Names follow the
   `events/year=YYYY/month=MM/day=DD/hour=HH/p<part>-<startOff>-<endOff>.ndjson`
   convention. Spot-check a single blob:
   ```bash
   BLOB=$(az storage blob list --account-name "$ARCHIVE_SA" \
     --container-name telemetry-raw --auth-mode login \
     --prefix "events/year=$(date -u +%Y)/" \
     --query "[0].name" -o tsv)
   az storage blob download --account-name "$ARCHIVE_SA" \
     --container-name telemetry-raw --auth-mode login \
     --name "$BLOB" --file /dev/stdout
   ```
   Each line should be one JSON document with `id`, `device_id`,
   `partition_id`, `offset`, `sequence_number`, `enqueued_time`,
   `received_time` plus the original payload fields.

## What's NOT in this slice

- Parquet conversion of the NDJSON archive (downstream batch job, not
  this writer).
- Lifecycle policy on `telemetry-raw` (hot → cool → archive). Defer
  until empirical sizing exists.
- DLQ / poison-message handling beyond default trigger retry.
- Identity-only enforcement on the archive SA
  (`shared_access_key_enabled=false` flip is a separate slice).

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
- **`event_received` logs but no blobs in `telemetry-raw`.** Almost
  certainly the writer MI's `Storage Blob Data Contributor` role
  hasn't propagated yet (60s+ on a fresh apply). Confirm with
  `FunctionAppLogs | where Message contains "AuthorizationPermission"`
  in LAW. If the role is propagated and writes still fail, double-
  check that `BLOB_ARCHIVE_ACCOUNT` in app settings ends with a
  trailing `/` (it's `primary_blob_endpoint`, not the FQDN).
