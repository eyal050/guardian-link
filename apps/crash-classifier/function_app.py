"""Crash-classifier Function App.

Reads crash_suspect events from the 'telemetry' Event Hub on the
'crash-classifier' consumer group. For each suspect:

  1. Fetches the preceding telemetry window from Cosmos DB.
  2. Calls the ML endpoint (or a hardcoded stub when ML_ENDPOINT_URL is
     not set).
  3. Publishes a crash_confirmed message to the Service Bus queue when
     confidence >= CLASSIFIER_CONFIDENCE_THRESHOLD (default 0.9).
  4. Logs a crash_below_threshold event for retrospective analysis when
     confidence < threshold.

Non-crash events (event_type != crash_suspect) are silently ignored —
the classifier shares the 'telemetry' hub with the writer and must not
act on routine telemetry.

Identity-based connections throughout:
  - EH trigger: EH_TELEMETRY__fullyQualifiedNamespace + __credential
  - Cosmos reads: DefaultAzureCredential (MI has Data Reader role)
  - Service Bus send: DefaultAzureCredential (MI has Data Sender on queue)
"""

from __future__ import annotations

import json
import logging
import os
import urllib.request
from datetime import datetime, timedelta, timezone
from typing import Any

import azure.functions as func
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential


app = func.FunctionApp()

_CONFIDENCE_THRESHOLD = float(os.environ.get("CLASSIFIER_CONFIDENCE_THRESHOLD", "0.9"))
_WINDOW_SECONDS = int(os.environ.get("TELEMETRY_WINDOW_SECONDS", "30"))

_cosmos_container_client = None
_sb_sender = None


def _get_cosmos_container():
    global _cosmos_container_client
    if _cosmos_container_client is None:
        cred = DefaultAzureCredential()
        client = CosmosClient(url=os.environ["COSMOS_ENDPOINT"], credential=cred)
        db = client.get_database_client(os.environ["COSMOS_DATABASE"])
        _cosmos_container_client = db.get_container_client(os.environ["COSMOS_CONTAINER"])
    return _cosmos_container_client


def _get_sb_sender():
    global _sb_sender
    if _sb_sender is None:
        from azure.servicebus import ServiceBusClient  # lazy — top-level import may break v2 discovery
        cred = DefaultAzureCredential()
        sb_client = ServiceBusClient(
            fully_qualified_namespace=os.environ["SB_NAMESPACE_FQDN"],
            credential=cred,
        )
        _sb_sender = sb_client.get_queue_sender(
            queue_name=os.environ.get("SB_CRASH_QUEUE", "crash-confirmed")
        )
    return _sb_sender


def _fetch_telemetry_window(
    container: Any,
    device_id: str,
    end_time: str,
    window_seconds: int,
) -> list[dict[str, Any]]:
    try:
        end_dt = datetime.fromisoformat(end_time)
    except ValueError:
        return []

    start_time = (end_dt - timedelta(seconds=window_seconds)).isoformat()

    items = container.query_items(
        query=(
            "SELECT * FROM c "
            "WHERE c.device_id=@device_id "
            "AND c.timestamp>=@start_time "
            "AND c.timestamp<=@end_time"
        ),
        parameters=[
            {"name": "@device_id", "value": device_id},
            {"name": "@start_time", "value": start_time},
            {"name": "@end_time", "value": end_time},
        ],
        partition_key=device_id,
        max_item_count=50,
    )
    return list(items)


def _call_ml(window_events: list[dict[str, Any]]) -> dict[str, Any]:
    """Call ML endpoint or return a stub when ML_ENDPOINT_URL is not set."""
    url = os.environ.get("ML_ENDPOINT_URL", "")
    if not url:
        return {"is_crash": True, "confidence": 0.95}

    payload = json.dumps(window_events).encode()
    req = urllib.request.Request(
        url, data=payload, method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


@app.event_hub_message_trigger(
    arg_name="event",
    event_hub_name="telemetry",
    connection="EH_TELEMETRY",
    consumer_group="crash-classifier",
)
def classify_crash(event: func.EventHubEvent) -> None:
    properties = (event.metadata or {}).get("Properties") or {}
    event_type = str(properties.get("eventType", ""))

    if event_type != "crash_suspect":
        return

    body: dict[str, Any] = {}
    try:
        raw = event.get_body().decode("utf-8")
        if raw:
            body = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        body = {}

    device_id = str(body.get("device_id", ""))
    crash_timestamp = str(body.get("timestamp", ""))

    if not device_id or not crash_timestamp:
        logging.warning(
            "event_dropped reason=missing_required_fields offset=%s",
            getattr(event, "offset", ""),
        )
        return

    window = _fetch_telemetry_window(
        _get_cosmos_container(), device_id, crash_timestamp, _WINDOW_SECONDS
    )

    if not window:
        logging.info(
            "empty_telemetry_window device_id=%s crash_timestamp=%s window_seconds=%d",
            device_id, crash_timestamp, _WINDOW_SECONDS,
        )

    result = _call_ml(window)
    confidence: float = float(result.get("confidence", 0.0))

    if confidence < _CONFIDENCE_THRESHOLD:
        logging.info(
            "crash_below_threshold device_id=%s confidence=%.3f threshold=%.4f",
            device_id, confidence, _CONFIDENCE_THRESHOLD,
        )
        return

    if event.enqueued_time:
        eh_time = event.enqueued_time
        if eh_time.tzinfo is None:
            eh_time = eh_time.replace(tzinfo=timezone.utc)
        latency_ms = (datetime.now(timezone.utc) - eh_time).total_seconds() * 1000
        logging.info(
            "classifier_latency_ms=%.1f device_id=%s confidence=%.3f",
            latency_ms, device_id, confidence,
        )

    from azure.servicebus import ServiceBusMessage  # lazy — keep in sync with _get_sb_sender
    message_id = f"{device_id}|{crash_timestamp}"
    sb_payload = {
        "device_id": device_id,
        "crash_timestamp": crash_timestamp,
        "confidence": confidence,
        "classifier_version": "stub-v1",
    }
    if event.enqueued_time:
        eh_time = event.enqueued_time
        if eh_time.tzinfo is None:
            eh_time = eh_time.replace(tzinfo=timezone.utc)
        sb_payload["eh_enqueued_time"] = eh_time.isoformat()
    msg = ServiceBusMessage(
        body=json.dumps(sb_payload).encode(),
        message_id=message_id,
    )
    _get_sb_sender().send_messages(msg)

    logging.info(
        "crash_confirmed_published device_id=%s confidence=%.3f message_id=%s",
        device_id, confidence, message_id,
    )
