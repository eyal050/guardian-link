# Notifier Function App — Design Spec

**Date:** 2026-04-27  
**Status:** Approved

---

## 1. Overview

The Notifier is an Azure Function that consumes confirmed crash events from the
Service Bus `crash-confirmed` queue and fans out notifications to a user's
emergency contacts via ACS SMS, ACS Email, and Azure Notification Hubs (stubbed).
It is the terminal step in the life-safety notification pipeline.

---

## 2. Architecture

```
Service Bus                    Notifier Function App
crash-confirmed ──SB trigger──▶  1. Read Cosmos: notification record exists?
                                    └─ completed  → Complete(), return
                                    └─ in_flight  → load channels_completed (resume cursor)
                                    └─ missing    → write in_flight record to Cosmos
                                 2. Query Postgres: device_id → user → emergency contacts
                                 3. Fan-out (skip channels already in channels_completed):
                                    ├─ ACS SMS
                                    ├─ ACS Email
                                    └─ Notification Hubs (stubbed: log only)
                                 4. Update Cosmos record → status=completed
                                 5. return  (SB Complete() is implicit on clean return)

                                 On any exception: propagate → SB redelivers
```

**Idempotency key:** `message_id = "{device_id}|{crash_timestamp}"` — set by the
crash-classifier, stable across all SB redeliveries. The Cosmos notification record
is keyed on this value.

**Retry mechanism:** SB at-least-once delivery. Lock duration 5 min, max delivery
count 5, then DLQ. No custom retry loops inside the function — SB redelivery is
the retry.

**Fan-out error semantics:** All-or-nothing. If any channel raises, the exception
propagates, SB does not receive Complete(), and the message is redelivered. On
redeliver, `channels_completed` in the Cosmos record is the resume cursor — already-
sent channels are skipped.

**Edge case — no contacts:** If Postgres returns an empty contact list, log a
warning (`no_contacts_found`), mark the Cosmos record `completed`, and return
cleanly. Do not redeliver indefinitely for a configuration gap.

---

## 3. Infrastructure (Terraform)

### New file: `terraform/guardianlink-dev/postgres.tf`

Resources:
- `azurerm_postgresql_flexible_server` — Standard_B1ms, no HA, public network
  access (dev), West Europe
- `azurerm_postgresql_flexible_server_firewall_rule` — allow Azure services
  (`0.0.0.0` to `0.0.0.0`)
- `azurerm_postgresql_flexible_server_database` — database name `guardianlink`
- `random_password.postgres_admin` → `azurerm_key_vault_secret.postgres_admin_password`
- `random_password.postgres_notifier` → `azurerm_key_vault_secret.postgres_notifier_password`
- `null_resource` + `local-exec` to run `apps/notifier/schema.sql` on first apply
  (idempotent: uses `CREATE TABLE IF NOT EXISTS`). Requires `psql` installed on the
  machine running `terraform apply`. The `local-exec` uses the admin credentials from
  Key Vault output to connect.

### New file: `terraform/guardianlink-dev/notifier.tf`

Resources:
- `azurerm_communication_service` — ACS resource, data location West Europe
- `azurerm_email_communication_service` — ACS Email capability
- `azurerm_email_communication_service_domain` — managed Azure domain
  (`*.azurecomm.net`; no custom domain in dev)
- `azurerm_service_plan` — Consumption Y1, Linux (separate plan from
  crash-classifier; shared plan = shared fate on the crash path)
- `azurerm_linux_function_app` — notifier Function App, Python 3.10, system-
  assigned managed identity
- RBAC role assignments for notifier MI:
  - `Azure Service Bus Data Receiver` scoped to `crash-confirmed` queue
  - `Cosmos DB Built-in Data Contributor` scoped to the Cosmos account
  - `Contributor` on the ACS resource
  - `Key Vault Secrets User` on the Key Vault

App settings:
| Setting | Value |
|---|---|
| `SB_NAMESPACE__fullyQualifiedNamespace` | `${sbns}.servicebus.windows.net` (identity-based SB trigger binding) |
| `SB_CRASH_QUEUE` | `crash-confirmed` |
| `COSMOS_ENDPOINT` | Cosmos account endpoint |
| `COSMOS_DATABASE` | database name |
| `COSMOS_NOTIFICATIONS_CONTAINER` | `notifications` |
| `ACS_ENDPOINT` | ACS resource endpoint |
| `ACS_SENDER_PHONE` | provisioned ACS phone number — **manually set post-apply** (no TF resource for ACS phone number acquisition; provision via Azure portal under the ACS resource) |
| `ACS_SENDER_EMAIL` | `DoNotReply@<managed-domain>` |
| `POSTGRES_HOST` | Flexible Server FQDN |
| `POSTGRES_USER` | `notifier` |
| `POSTGRES_DB` | `guardianlink` |
| `POSTGRES_PASSWORD` | Key Vault reference |

### Cosmos: new `notifications` container

Added to `cosmos.tf`:
- Container name `notifications`, partition key `/device_id`, no TTL (crash
  records retained indefinitely as safety evidence)

---

## 4. Data Model

### Cosmos notification record

```json
{
  "id": "dev-abc-123|2026-04-27T14:32:00Z",
  "device_id": "dev-abc-123",
  "crash_timestamp": "2026-04-27T14:32:00Z",
  "confidence": 0.95,
  "status": "in_flight",
  "channels_completed": ["sms", "email"],
  "channels_failed": [],
  "created_at": "2026-04-27T14:32:01Z",
  "completed_at": null
}
```

`status` values: `in_flight` | `completed`  
`channels_completed` / `channels_failed`: subset of `["sms", "email", "push"]`

### Postgres schema (`apps/notifier/schema.sql`)

```sql
CREATE TABLE IF NOT EXISTS users (
  user_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name     TEXT NOT NULL,
  email    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
  device_id TEXT PRIMARY KEY,
  user_id   UUID NOT NULL REFERENCES users(user_id)
);

CREATE TABLE IF NOT EXISTS emergency_contacts (
  contact_id UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID    NOT NULL REFERENCES users(user_id),
  name       TEXT    NOT NULL,
  phone      TEXT,   -- E.164 format; nullable (contact may not receive SMS)
  email      TEXT,   -- nullable
  push_token TEXT,   -- nullable; for Notification Hubs stub
  active     BOOLEAN NOT NULL DEFAULT TRUE
);
```

### Seed data (`apps/notifier/seed.sql`)

One test user, one device mapped to the simulator's `device_id`, one emergency
contact with a real phone number and email for end-to-end verification. Not
committed to git (contains real contact details); documented in README as a
manual step.

---

## 5. Application Code

### File: `apps/notifier/function_app.py`

Module-level lazy singletons (same pattern as crash-classifier: lazy imports
inside getter functions to avoid Python v2-model worker discovery failure):
- Cosmos container client (`notifications`)
- SB receiver (not needed — SB trigger handles the receiver)
- ACS `SmsClient`
- ACS `EmailClient`
- psycopg2 connection (module-level, reconnect on `OperationalError`)

### Control flow

```python
@app.service_bus_queue_trigger(
    arg_name="msg",
    queue_name="crash-confirmed",
    connection="SB_NAMESPACE",
)
def notify_crash(msg: func.ServiceBusMessage) -> None:
    body = json.loads(msg.get_body())
    device_id       = body["device_id"]
    crash_timestamp = body["crash_timestamp"]
    confidence      = body["confidence"]
    message_id      = f"{device_id}|{crash_timestamp}"

    container = _get_cosmos_container()
    record = _get_notification_record(container, message_id, device_id)

    if record and record["status"] == "completed":
        return  # idempotency short-circuit

    channels_completed = record["channels_completed"] if record else []
    if not record:
        _upsert_record(container, message_id, device_id, crash_timestamp,
                       confidence, status="in_flight", channels_completed=[])

    contacts = _get_contacts(device_id)
    if not contacts:
        logging.warning("no_contacts_found device_id=%s", device_id)
        _upsert_record(..., status="completed", completed_at=utcnow())
        return

    if "sms" not in channels_completed:
        _send_sms(contacts)
        channels_completed.append("sms")
        _upsert_record(..., channels_completed=channels_completed)

    if "email" not in channels_completed:
        _send_email(contacts)
        channels_completed.append("email")
        _upsert_record(..., channels_completed=channels_completed)

    if "push" not in channels_completed:
        _send_push_stub(contacts)   # logs only
        channels_completed.append("push")
        _upsert_record(..., channels_completed=channels_completed)

    _upsert_record(..., status="completed", completed_at=utcnow())
    # SB Complete() is implicit on clean return
```

### App Insights custom events

| Event | Properties |
|---|---|
| `notification_sent` | `device_id`, `channel`, `contact_id`, `message_id` |
| `notification_failed` | `device_id`, `channel`, `exception_type`, `message_id` |
| `no_contacts_found` | `device_id`, `message_id` |
| `notification_idempotency_skip` | `device_id`, `message_id` |

### Dependencies (`apps/notifier/requirements.txt`)

```
azure-functions
azure-servicebus
azure-cosmos
azure-communication-sms
azure-communication-email
azure-identity
psycopg2-binary
opencensus-ext-azure
```

---

## 6. Tests

File: `apps/notifier/tests/test_notifier.py`

| Test | What it verifies |
|---|---|
| `test_idempotency_completed` | Cosmos returns `status=completed` → zero ACS/Postgres calls, function returns |
| `test_resume_sms_done` | `channels_completed=["sms"]` → only email + push attempted |
| `test_happy_path` | No record → all channels attempted, Cosmos updated to `completed` |
| `test_channel_failure_propagates` | ACS SMS raises → exception propagates (no Complete) |
| `test_no_contacts` | Postgres returns `[]` → warn + mark completed, no channel calls |

All Azure SDK and psycopg2 calls mocked via `unittest.mock`.

---

## 7. Decisions recorded here (add to architecture.md after approval)

- **Notifier compute:** Function App, Consumption Y1, separate plan from crash-classifier (avoid shared fate on the crash path).
- **Notification channels:** ACS SMS + ACS Email (both real); Azure Notification Hubs stubbed (no registered mobile device in dev). SendGrid excluded — ACS covers both SMS and email, no need for a third-party dependency.
- **Postgres auth:** Password in Key Vault reference (not MI auth). MI auth to Postgres Flexible Server requires a `null_resource` SQL provisioner to create the Entra-mapped role, adding complexity without interview value at this stage.
- **Idempotency:** Cosmos `notifications` container; `id = device_id|crash_timestamp`; `channels_completed` list is the resume cursor on redeliver.
- **Fan-out error semantics:** All-or-nothing. Exception propagates → SB redelivers. No custom retry loops.
- **No-contacts edge case:** Log warning, mark completed, do not redeliver.
