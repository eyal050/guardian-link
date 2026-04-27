"""Notifier Function App.

Reads crash_confirmed messages from the Service Bus 'crash-confirmed' queue,
looks up emergency contacts from PostgreSQL, and fans out to:
  - ACS SMS
  - ACS Email
  - Azure Notification Hubs (stubbed: logs only — no registered device in dev)

Idempotency: a 'notifications' Cosmos document keyed on
'{device_id}|{crash_timestamp}' tracks status and channels_completed.
On redeliver, completed channels are skipped; a status=completed record
short-circuits the entire function immediately.

Fan-out error semantics: any channel exception propagates. The Service Bus
broker does not receive Complete() and redelivers. No custom retry loops —
SB redelivery is the retry mechanism (max_delivery_count=5, then DLQ).
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

import azure.functions as func
from azure.cosmos import CosmosClient
from azure.cosmos.exceptions import CosmosResourceNotFoundError
from azure.identity import DefaultAzureCredential


app = func.FunctionApp()

_cosmos_container_client = None
_pg_conn = None
_sms_client = None
_email_client = None


def _get_cosmos_container():
    global _cosmos_container_client
    if _cosmos_container_client is None:
        cred = DefaultAzureCredential()
        client = CosmosClient(url=os.environ["COSMOS_ENDPOINT"], credential=cred)
        db = client.get_database_client(os.environ["COSMOS_DATABASE"])
        _cosmos_container_client = db.get_container_client(
            os.environ["COSMOS_NOTIFICATIONS_CONTAINER"]
        )
    return _cosmos_container_client


def _get_pg_conn():
    global _pg_conn
    import psycopg2  # lazy — avoid top-level import breaking v2 worker discovery
    if _pg_conn is None or _pg_conn.closed:
        _pg_conn = psycopg2.connect(
            host=os.environ["POSTGRES_HOST"],
            dbname=os.environ["POSTGRES_DB"],
            user=os.environ["POSTGRES_USER"],
            password=os.environ["POSTGRES_PASSWORD"],
            sslmode="require",
            connect_timeout=10,
        )
    return _pg_conn


def _get_sms_client():
    global _sms_client
    if _sms_client is None:
        from azure.communication.sms import SmsClient  # lazy
        _sms_client = SmsClient.from_connection_string(os.environ["ACS_CONNECTION_STRING"])
    return _sms_client


def _get_email_client():
    global _email_client
    if _email_client is None:
        from azure.communication.email import EmailClient  # lazy
        _email_client = EmailClient.from_connection_string(os.environ["ACS_CONNECTION_STRING"])
    return _email_client


def _get_notification_record(
    container: Any, message_id: str, device_id: str
) -> dict[str, Any] | None:
    try:
        return container.read_item(item=message_id, partition_key=device_id)
    except CosmosResourceNotFoundError:
        return None


def _upsert_notification_record(container: Any, record: dict[str, Any]) -> None:
    container.upsert_item(record)


def _get_contacts(device_id: str) -> list[dict[str, Any]]:
    conn = _get_pg_conn()
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT ec.contact_id::text, ec.name, ec.phone, ec.email, ec.push_token
            FROM emergency_contacts ec
            JOIN devices d ON d.user_id = ec.user_id
            WHERE d.device_id = %s AND ec.active = TRUE
            """,
            (device_id,),
        )
        rows = cur.fetchall()
    return [
        {
            "contact_id": row[0],
            "name": row[1],
            "phone": row[2],
            "email": row[3],
            "push_token": row[4],
        }
        for row in rows
    ]


def _send_sms(contacts: list[dict[str, Any]], device_id: str, crash_timestamp: str) -> None:
    client = _get_sms_client()
    sender = os.environ["ACS_SENDER_PHONE"]
    message = (
        f"URGENT: Crash detected for device {device_id} at {crash_timestamp}. "
        "Please check on the device owner immediately."
    )
    for contact in contacts:
        if not contact.get("phone"):
            continue
        client.send(from_=sender, to=[contact["phone"]], message=message)
        logging.info(
            "notification_sent channel=sms device_id=%s contact_id=%s",
            device_id,
            contact["contact_id"],
        )


def _send_email(contacts: list[dict[str, Any]], device_id: str, crash_timestamp: str) -> None:
    client = _get_email_client()
    sender = os.environ["ACS_SENDER_EMAIL"]
    for contact in contacts:
        if not contact.get("email"):
            continue
        email_msg = {
            "senderAddress": sender,
            "recipients": {
                "to": [{"address": contact["email"], "displayName": contact["name"]}]
            },
            "content": {
                "subject": f"URGENT: Crash Alert for device {device_id}",
                "plainText": (
                    f"A crash has been detected for device {device_id} at {crash_timestamp}. "
                    "Please check on the device owner immediately."
                ),
            },
        }
        poller = client.begin_send(email_msg)
        poller.result(timeout=30)
        logging.info(
            "notification_sent channel=email device_id=%s contact_id=%s",
            device_id,
            contact["contact_id"],
        )


def _send_push_stub(contacts: list[dict[str, Any]], device_id: str) -> None:
    for contact in contacts:
        if not contact.get("push_token"):
            continue
        logging.info(
            "notification_push_stub device_id=%s contact_id=%s push_token=%.8s...",
            device_id,
            contact["contact_id"],
            contact["push_token"],
        )


@app.service_bus_queue_trigger(
    arg_name="msg",
    queue_name="crash-confirmed",
    connection="SB_NAMESPACE",
)
def notify_crash(msg: func.ServiceBusMessage) -> None:
    body: dict[str, Any] = {}
    try:
        body = json.loads(msg.get_body().decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        logging.error("notify_crash_body_parse_error")
        return

    device_id = str(body.get("device_id", ""))
    crash_timestamp = str(body.get("crash_timestamp", ""))
    confidence = float(body.get("confidence", 0.0))

    if not device_id or not crash_timestamp:
        logging.warning("notify_crash_missing_fields device_id=%s", device_id)
        return

    message_id = f"{device_id}|{crash_timestamp}"
    now = datetime.now(timezone.utc).isoformat()
    container = _get_cosmos_container()

    record = _get_notification_record(container, message_id, device_id)

    if record and record.get("status") == "completed":
        logging.info("notification_idempotency_skip message_id=%s", message_id)
        return

    channels_completed: list[str] = record["channels_completed"] if record else []
    if not record:
        record = {
            "id": message_id,
            "device_id": device_id,
            "crash_timestamp": crash_timestamp,
            "confidence": confidence,
            "status": "in_flight",
            "channels_completed": [],
            "channels_failed": [],
            "created_at": now,
            "completed_at": None,
        }
        _upsert_notification_record(container, record)

    contacts = _get_contacts(device_id)
    if not contacts:
        logging.warning("no_contacts_found device_id=%s message_id=%s", device_id, message_id)
        record["status"] = "completed"
        record["completed_at"] = now
        _upsert_notification_record(container, record)
        return

    if "sms" not in channels_completed:
        _send_sms(contacts, device_id, crash_timestamp)
        channels_completed.append("sms")
        record["channels_completed"] = channels_completed
        _upsert_notification_record(container, record)

    if "email" not in channels_completed:
        _send_email(contacts, device_id, crash_timestamp)
        channels_completed.append("email")
        record["channels_completed"] = channels_completed
        _upsert_notification_record(container, record)

    if "push" not in channels_completed:
        _send_push_stub(contacts, device_id)
        channels_completed.append("push")
        record["channels_completed"] = channels_completed
        _upsert_notification_record(container, record)

    record["status"] = "completed"
    record["completed_at"] = now
    _upsert_notification_record(container, record)
    # SB Complete() is implicit on clean return
