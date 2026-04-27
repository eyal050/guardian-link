# GuardianLink Architecture

## The product, in one paragraph

A user wears a BLE device (or runs a mobile app) that continuously samples accelerometer, GPS, battery, and heart-rate data. Telemetry is streamed to Azure. Most of it is just stored for analytics. When the onboard firmware *suspects* a crash, it flags the event; a cloud-side ML model confirms or rejects. On confirmed crashes, the platform notifies the user's emergency contacts over multiple channels within seconds.

## High-level diagram

```
 ┌────────────────────┐      ┌────────────────────┐
 │ BLE device / phone │─────▶│ Mobile app gateway │
 └────────────────────┘      └──────────┬─────────┘
                                        │ MQTT/HTTPS
                                        ▼
                              ┌────────────────────┐
                              │    Azure IoT Hub   │
                              └──────────┬─────────┘
                                         │
                                         ▼
                              ┌────────────────────┐
                              │    Event Grid /    │
                              │   Event Hubs (?)   │  ← open decision
                              └──────────┬─────────┘
                         ┌───────────────┼───────────────┐
                         ▼               ▼               ▼
                 ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
                 │ Telemetry   │  │ Crash       │  │ Metrics     │
                 │ writer (Fn) │  │ classifier  │  │ function    │
                 └──────┬──────┘  │   (Fn)      │  └──────┬──────┘
                        │         └──────┬──────┘         │
          ┌─────────────┴──┐             │                │
          ▼                ▼             ▼                ▼
  ┌──────────────┐  ┌────────────┐  ┌─────────────┐  ┌──────────────┐
  │  Cosmos DB   │  │ Blob (raw  │  │ ML endpoint │  │ App Insights │
  │  (hot store) │  │  telemetry)│  │ (Container  │  │              │
  └──────────────┘  └────────────┘  │  App stub)  │  └──────────────┘
                                    └──────┬──────┘
                                           │ if crash confirmed
                                           ▼
                                    ┌────────────┐
                                    │ Notifier   │
                                    │   (Fn)     │
                                    └──┬──┬──┬───┘
                          ┌────────────┘  │  └──────────────┐
                          ▼               ▼                 ▼
                      ┌───────┐      ┌─────────┐      ┌─────────────┐
                      │  ACS  │      │   ACS   │      │ Notification│
                      │ (SMS) │      │ (email) │      │ Hubs (push, │
                      │       │      │         │      │   stubbed)  │
                      └───────┘      └─────────┘      └─────────────┘

 ┌─────────────────┐          ┌──────────────────┐        ┌──────────────┐
 │   API Mgmt      │─────────▶│ user-api (Fn or  │───────▶│  PostgreSQL  │
 │   (public)      │          │ Container App)   │        │  Flexible    │
 └─────────────────┘          └──────────────────┘        └──────────────┘

 Cross-cutting:
   • Key Vault  ← all secrets, connection strings, certs
   • Log Analytics workspace  ← all logs land here
   • Managed Identities everywhere possible (no connection-string auth between services)
   • Private endpoints for data stores (dev may skip this for cost)
```

## Components and responsibilities

### Ingestion layer

**Azure IoT Hub**
- Terminates device connections (MQTT over TLS).
- Device identity and per-device auth (X.509 preferred, SAS for the simulator).
- Routes messages to the eventing backbone based on message properties (e.g., `eventType=crash_suspect` routes differently than `eventType=telemetry`).
- Shared-access policies locked down; only the simulator gets `device` scope.

**Why IoT Hub and not Event Hubs directly?** Device identity and bidirectional comms (cloud-to-device, twin state). For a product with remote devices, IoT Hub's device registry matters more than raw throughput.

### Eventing backbone

**Open decision** — see `brainstorming-topics.md` #3.

- **Event Grid** → pub/sub, push-based, great for reactive Functions, cheaper at low volume.
- **Event Hubs** → high-throughput, pull-based, better for analytics pipelines and replay.
- **Service Bus** → transactional semantics, dead-letter queues, ordering.

The crash notification path probably wants **at-least-once with dead-letter** (Service Bus), the telemetry path wants **high-throughput streaming** (Event Hubs), and some low-volume lifecycle events fit **Event Grid**. Multiple backbones are common in production but add operational surface. Discuss tradeoff.

### Processing layer (Azure Functions or Container Apps)

- **Telemetry writer** — writes hot telemetry to Cosmos DB, raw batches to Blob (Parquet). Stateless, scales on queue depth.
- **Crash classifier** — receives crash-suspect events, pulls the relevant telemetry window, calls ML endpoint, publishes `crash_confirmed` or `crash_rejected`.
- **Notifier** — consumes `crash_confirmed`, looks up emergency contacts from PostgreSQL, fans out to SMS/email/push. Must be idempotent (see failure #1).
- **Metrics function** — consumes all events, emits custom App Insights metrics (events/sec, classifier latency, notification latency).

### Storage layer

**Cosmos DB** — hot store for recent telemetry, user-facing queries, event lookups.
- Partition key: open decision. `deviceId` is obvious; `deviceId + yyyyMM` handles hot partitions better.
- TTL on telemetry documents (e.g., 30 days in hot store).
- Throughput: autoscale in dev, dedicated in prod.

**Blob Storage** — cold/raw telemetry archive, crash event payloads, ML training data.
- Lifecycle policy: hot → cool after 30d → archive after 180d.
- Immutable blob policy for crash events (regulatory evidence).

**PostgreSQL Flexible Server** — users, emergency contacts, device registry, consent records.
- Why Postgres and not Cosmos for this? Relational data with strong consistency needs (a missed emergency contact is a safety issue, not a latency issue). Plus the JD explicitly names Postgres.

### API layer

**API Management** — public edge for the mobile app.
- Products/subscriptions model for mobile app key.
- Rate limiting per user.
- JWT validation (Entra ID or custom B2C).
- Request/response logging to App Insights.

**user-api** — CRUD for user profile, emergency contacts, device pairing, consent.
- Azure Function with HTTP triggers OR Container App. Open decision.

### ML support (stub, not real MLOps)

- A dummy Python container hosted on Azure Container Apps that accepts a telemetry window and returns `{"is_crash": bool, "confidence": float}`.
- Version the container image. Deploy v1 and v2 side-by-side behind a traffic split.
- That's enough to talk about blue/green deploys, canary, and model versioning without over-investing.

### Observability

- **Log Analytics workspace** — single workspace for dev, logs from every service.
- **Application Insights** — connected to the workspace. Instrument every function. Custom events for business metrics (`crash_confirmed`, `notification_sent`, `notification_failed`).
- **Dashboards** — at least one Azure Workbook with: ingestion rate, classifier latency p50/p95/p99, notification success rate, Cosmos RU consumption, cost-to-date.
- **Alerts** — at least five, wired to an action group. Examples: notification failure rate > 1%, Cosmos 429s > threshold, classifier latency p95 > 2s, Function execution errors > N/min, Key Vault access denied.

### Security & identity

- **Managed identities** everywhere. No connection strings in config for service-to-service auth.
- **Key Vault** for the secrets that unavoidably exist (SendGrid API key, ACS connection string, JWT signing keys).
- **RBAC** on Key Vault, Cosmos, Storage, Postgres — principle of least privilege.
- **Private endpoints** on data stores in prod. In dev, public with firewall rules is fine and cheaper.
- **Entra ID** for operator access to the subscription.

### CI/CD

- **Azure DevOps** pipelines (not GitHub Actions — the JD is specific).
- Separate pipelines: `infra` (terraform), `apps` (function/container builds).
- Infra pipeline stages: `validate → plan → (manual approval) → apply`.
- App pipeline: `build → test → deploy-dev → (approval) → deploy-prod`.
- Release annotations in App Insights so deploys show up on graphs.

## Decisions already made (do not re-litigate)

1. Terraform for IaC, not Bicep.
2. Azure Functions are the default compute; escalate to Container Apps only where justified.
3. Python for Functions (aligns with the ML stub and simulator).
4. One Log Analytics workspace, not per-service.
5. Cosmos DB Core (SQL) API. Not Mongo, not Cassandra.
6. Single region for the exercise. Multi-region is a discussion, not a build.
7. **Eventing backbone is split three ways.**
   - **Event Hubs** for device telemetry — high volume, partitioned by `deviceId`, consumer-group model, replayable so the classifier can be re-run against historical windows.
   - **Service Bus** for the crash notification pipeline — at-least-once + DLQ required because crash events cannot be dropped; the notifier is idempotent to tolerate redelivery (see failure #1).
   - **Event Grid** for lifecycle and platform events — device paired, user created, plus Azure system events (e.g., blob-created). Chosen over folding into Service Bus because (a) platform system-topics are Event Grid-native, (b) consumers are small reactive Functions where push beats pull, (c) pay-per-event floor is lower at dev-env volumes.
   - **Routing rule:** IoT Hub routes all device messages to Event Hubs only. The classifier Function publishes `crash_confirmed` to Service Bus downstream. The "this is life-safety" boundary sits at the classifier's confidence threshold, not at ingest — so low-confidence suspects never enter the hardened queue.
8. **Telemetry-writer is a Function App, not a Container App.** Linux Consumption plan, Python 3.10, identity-based Event Hubs trigger on a dedicated `telemetry-writer` consumer group. Chosen because (a) the Functions EH trigger handles partition assignment + checkpointing internally in `AzureWebJobsStorage`, removing the only operational concern that would have justified the extra surface of a Container App; (b) it's a stateless map-and-write — no runtime-control needs that would force Container Apps; (c) Consumption scales to zero between simulator runs, matching the destroy-nightly cost discipline. The local debug consumer in `apps/consumer/` keeps its own `BlobCheckpointStore` against the `eh-checkpoints` container — two consumer-group strategies for two roles, deliberately. Container Apps remain the right answer for the ML classifier stub (scipy/torch deps, longer-running batch work).
9. **Cosmos DB: serverless, `/device_id` partition key, AAD-only.** Serverless capacity (not provisioned autoscale) — the dev workload is bursty and the stack is destroyed nightly, so paying-per-RU beats paying for an idle floor proportional to a configured ceiling. Production would flip to provisioned-autoscale once load is sustained; that switch requires recreating the account, so the decision is sticky. Partition key `/device_id` (matching the simulator's snake_case payload) is driven by the read pattern "last N minutes of telemetry for device X" — single-partition lookup with a time-range filter. Migration trigger: if any single device exceeds ~10% of total writes, flip to a synthetic `/device_id_yyyyMM` key (also a recreate). `local_authentication_disabled = true` matches the stack's identity-everywhere posture (EH namespace, IoT Hub routing); the future telemetry-writer Function MI will get `Cosmos DB Built-in Data Contributor` scoped to the account. Single-region (West Europe), Session consistency. Default 30-day TTL on the `telemetry` container — raw archive in Blob handles longer retention. crash_suspect lookups remain cross-partition and that's accepted at this scale; routing crash events to a separate container is a later slice tied to the classifier.
10. **Telemetry-writer slice β: raw events archive to a separate Blob storage account, NDJSON, per-event.** The writer fans out: per-event Cosmos upsert (slice α+) plus per-event NDJSON blob to Blob.
    - **Separate storage account** (`stglraw…`, distinct from the operational `stgl…` that backs `AzureWebJobsStorage` and the EH checkpoints container). Blast-radius: a destroy-recreate of the archive must not touch the host's content share or the consumer's checkpoint store. Identity-only enforcement on the archive can diverge from the operational account, which still needs shared keys for the Linux Consumption content share. Cost is ~zero in dev (Standard_LRS, low tx volume).
    - **Format: NDJSON** (one JSON event per line). Parquet matches the read pattern of a future training/backfill job better, but it forces pyarrow + buffer-and-flush logic + schema management. Defer Parquet until a downstream consumer of this archive actually exists; NDJSON is forward-compatible (a one-shot job can convert later).
    - **Per-event blob, deterministic name.** One block-blob per function invocation, named `events/year=YYYY/month=MM/day=DD/hour=HH/p<partition>-<offset>.ndjson`. Hive-style time partitions so a future Spark/Synapse job can mount this as a partitioned external table without rewriting paths. Offset in the filename makes a redelivered event overwrite the same blob (`overwrite=True`). The trigger uses the default `cardinality=ONE` (single-event signature); see the note below on why `cardinality=many` was rejected.
    - **`cardinality=many` incompatible with this worker.** Bisection confirmed: adding `cardinality=Cardinality.MANY` (or the string `"many"`) as a kwarg to `@app.event_hub_message_trigger` on the Linux Consumption Y1 Python v2 worker causes silent "0 functions found (Custom)" — the worker indexer aborts before emitting a Python traceback. No other change causes this. Per-event blobs have higher object count than per-batch, but the cost ceiling at dev volumes is negligible. Append blobs would cap at 50k blocks and create cross-instance contention anyway.
    - **Time-only partitioning, not device.** Blob reads are backfill / training scans across time ranges; per-device hot reads are Cosmos's job. Per-device prefixes would create one prefix per device, which lifecycle / inventory scans hate.
    - **Lifecycle policy (hot → cool → archive) deferred** until empirical sizing is available. Setting it now is guessing.
    - **Failure semantics: Cosmos-then-Blob in the same invocation, errors propagate.** EH redelivers the event; Cosmos upsert id is `<partition>-<offset>` (slice α+) and the blob name encodes the same offset, so a redeliver overwrites both deterministically.
    - **Role grant:** writer MI gets `Storage Blob Data Contributor` scoped to the `stglraw…` account (single container today; narrow to container scope when more containers exist).

11. **Crash classifier: 90% confidence threshold; ML stub pulls data from Cosmos.**
    - Events ≥ 90% confidence → published to the Service Bus `crash-confirmed` queue.
    - Events < 90%: logged to App Insights (custom event `crash_below_threshold`) with the confidence score and device ID for retrospective analysis. Not queued. No alert fired.
    - Rationale: 10% false-positive tolerance accepted at this stage to avoid missing real crashes; threshold is a config value, not hardcoded, so it can tighten as the model improves.
    - ML stub interface: the classifier fetches the telemetry window from Cosmos by `device_id` + time range before calling the stub. The stub receives the full window JSON, not just the raw IoT Hub payload. This mirrors what a real ML endpoint would need.
    - **Service Bus:** Standard tier namespace, identity-auth only (`local_authentication_enabled = false`). Single queue `crash-confirmed`: at-least-once, lock duration 5 min, max delivery count 5 (then DLQ), message TTL 14 days. Queue not topic — one consumer (notifier) today; upgrade to topic/subscription if a second consumer appears. Partitioned queues not enabled: crash volume is single-digit/hour, partitioning buys nothing and complicates DLQ inspection.

12. **Notifier: ACS for both SMS and email; push stubbed; no SendGrid.**
    - Azure Communication Services is the single ACS resource for SMS and email. SendGrid dropped as redundant — ACS supports both channels from one connection string and one KV secret.
    - Push notifications: `_send_push_stub` logs `notification_push_stub` but makes no SDK call. No Notification Hub device registration in dev; stub is the right cut given no registered devices exist.
    - SMS requires a purchased phone number (not included in dev — cost control). The `ACS_SENDER_PHONE` setting holds the number; set to a real number when acquired. Until then, SMS fails if contacts have a phone field, which SB redelivers up to `max_delivery_count=5` then DLQs.
    - Email uses ACS Azure-managed domain (`DoNotReply@<guid>.azurecomm.net`), no custom domain DNS needed.

13. **Notifier idempotency: Cosmos `notifications` container, `channels_completed` cursor.**
    - Container `notifications`, `/device_id` partition key, `id = {device_id}|{crash_timestamp}`.
    - `status`: `in_flight` → `completed`. On redeliver: `status=completed` record short-circuits the entire function; `status=in_flight` record has `channels_completed` as resume cursor — channels already done are skipped, failed channels are retried.
    - No TTL on the notifications container (crash records kept indefinitely; no regulatory delete needed in dev).

14. **Fan-out error semantics: exceptions propagate; SB redelivers.**
    - Any channel exception propagates out of `notify_crash`. SB does not receive `Complete()`. SB redelivers up to `max_delivery_count=5`, then DLQs. No custom retry loops — SB redelivery is the retry mechanism.
    - Resume-from-partial: because `channels_completed` is check-pointed after each channel, a redeliver skips completed channels and retries only the failed one. This turns a 5-attempt budget into a per-channel budget.

15. **Postgres auth for the notifier: password in Key Vault reference, not Entra ID.**
    - Entra ID auth against Postgres Flexible Server requires AAD-integrated roles and a custom `pg_hba.conf` row; significant complexity for zero interview-prep value.
    - Pattern used: `random_password` → KV secret → `@Microsoft.KeyVault(SecretUri=...)` in app settings. Function reads `POSTGRES_PASSWORD` as a plain string at runtime; KV reference resolution happens transparently in the Functions host.
    - `notifier` Postgres role has `SELECT` on `emergency_contacts` and `devices` and `users` (read-only). DDL is run by `psqladmin`.

16. **Key Vault: first KV in the stack; RBAC model.**
    - `enable_rbac_authorization = true` — all access via RBAC, no legacy access policies.
    - Operator gets `Key Vault Secrets Officer` (create, read, update, delete secrets).
    - Function managed identities get `Key Vault Secrets User` (read-only).
    - `purge_protection_enabled = false` in dev — allows `terraform destroy` to succeed without a 90-day wait.
    - `soft_delete_retention_days = 7` (Azure minimum).

17. **Metrics via `logging.info` to AppTraces, not the Application Insights custom metrics API.**
    - All pipeline metrics (throughput, classifier latency, end-to-end latency) are emitted as structured `logging.info` lines, queryable in `AppTraces` via KQL `extract()`.
    - Custom metrics API (`opencensus-ext-azure`) rejected: heavyweight dependency, separate telemetry channel, harder to test. The `logging.info` pattern is already established in every function in the stack.
    - Throughput: dedicated `metrics` Function App on its own `metrics` consumer group — independent EH offset tracking, zero impact on classifier or writer lag.
    - Classifier latency (`classifier_latency_ms`): computed inside `classify_crash` as `now() − event.enqueued_time` (T0). Logged only in the `confidence ≥ threshold` branch. `eh_enqueued_time` (T0 ISO string) is also embedded in the SB message body so the notifier can compute end-to-end.
    - Notification latency: `_log_notification_latency` helper in `notify_crash`, called after all channels complete. Logs `notification_stage_ms` (T2 − T1, where T1 = SB `enqueued_time_utc`) and, when `eh_enqueued_time` is present in the body, `end_to_end_ms` (T2 − T0). Missing timestamps are handled gracefully (warning, no exception).
    - Migration path: if cardinality-aware metric aggregation becomes important, these log lines can be replaced with `AzureMonitorMetricExporter` (OpenTelemetry) without changing any upstream code.

## Decisions deliberately left open

See `brainstorming-topics.md`. Do not let Claude Code silently decide these. Make the call yourself and write it down.
