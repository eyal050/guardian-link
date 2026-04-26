"""Telemetry-writer Function App.

Slice α: log every event to App Insights, verifying the identity-based
EH trigger fires.
Slice α+: also upsert each event into the Cosmos `telemetry` container
via DefaultAzureCredential resolving the Function App's MI.

Connection name 'EH_TELEMETRY' is supplied to the trigger by the host
via app settings EH_TELEMETRY__fullyQualifiedNamespace and
EH_TELEMETRY__credential=managedidentity (set in functions.tf).

Cosmos coordinates come from app settings COSMOS_ENDPOINT /
COSMOS_DATABASE / COSMOS_CONTAINER. The account has
local_authentication_disabled=true so the only path that works is
AAD via the MI.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any

import azure.functions as func
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential


app = func.FunctionApp()


# Lazy module-level singleton. Constructing CosmosClient at import time
# would force every test (and any local invocation without an Azure
# context) to spin up a real credential chain. Instead, build on first
# use inside the worker, then reuse across invocations — the Functions
# Python worker keeps the module loaded between calls.
_container_client = None


def _get_container():  # type: ignore[no-untyped-def]
    global _container_client
    if _container_client is None:
        credential = DefaultAzureCredential()
        client = CosmosClient(
            url=os.environ["COSMOS_ENDPOINT"],
            credential=credential,
        )
        db = client.get_database_client(os.environ["COSMOS_DATABASE"])
        _container_client = db.get_container_client(os.environ["COSMOS_CONTAINER"])
    return _container_client


def _build_document(
    body: dict[str, Any],
    event_type: str,
    partition_id: str,
    offset: str,
    sequence_number: int,
    enqueued_time: str,
    received_time: str,
) -> dict[str, Any]:
    """Compose the Cosmos document.

    Body fields are promoted to the top level so SQL queries hit them
    directly (`WHERE c.device_id = 'X'`). EH metadata is added as
    sibling top-level fields. `id` is deterministic per (partition,
    offset) — EH is at-least-once, so a redelivered event upserts onto
    the same document instead of creating a duplicate.
    """
    doc = dict(body)  # shallow copy; body keys take precedence on collision

    # Defensively coerce the partition-key value to string. Cosmos will
    # accept ints, but the producer always emits string device_ids and
    # mixing types within a partition key is a debugging headache.
    if "device_id" in doc:
        doc["device_id"] = str(doc["device_id"])

    doc["id"] = f"{partition_id}-{offset}"
    doc["event_type"] = event_type
    doc["partition_id"] = partition_id
    doc["offset"] = offset
    doc["sequence_number"] = sequence_number
    doc["enqueued_time"] = enqueued_time
    doc["received_time"] = received_time
    return doc


@app.event_hub_message_trigger(
    arg_name="event",
    event_hub_name="telemetry",
    connection="EH_TELEMETRY",
    consumer_group="telemetry-writer",
)
def telemetry_writer(event: func.EventHubEvent) -> None:
    body: dict[str, Any] = {}
    try:
        raw = event.get_body().decode("utf-8")
        if raw:
            body = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        body = {}

    properties = (event.metadata or {}).get("Properties") or {}
    event_type = str(properties.get("eventType", ""))
    partition_id = str(event.partition_key) if event.partition_key else "0"
    # EH SDK / Functions worker disagree on partition_id surface — the
    # SystemProperties dict is the canonical source when present.
    sys_props = (event.metadata or {}).get("SystemPropertiesArray") or {}
    if isinstance(sys_props, list) and sys_props:
        partition_id = str(sys_props[0].get("PartitionId", partition_id))
    elif isinstance(sys_props, dict):
        partition_id = str(sys_props.get("PartitionId", partition_id))

    enqueued_time = str(event.enqueued_time) if event.enqueued_time else ""
    from datetime import datetime, timezone
    received_time = datetime.now(timezone.utc).isoformat()

    # NOTE: the Functions Python v2 worker does NOT forward `extra=` dict
    # entries to App Insights customDimensions — only the rendered message
    # body. Embed the structured fields as named tokens in the message so
    # KQL can `parse` or `extract` them.
    logging.info(
        "event_received device_id=%s event_type=%s offset=%s seq=%s",
        body.get("device_id", ""),
        event_type,
        event.offset,
        event.sequence_number,
    )

    if not body.get("device_id"):
        # Without a device_id the document can't be partitioned. Log
        # and drop rather than write something we can't query later.
        logging.warning(
            "event_dropped reason=missing_device_id offset=%s",
            event.offset,
        )
        return

    doc = _build_document(
        body=body,
        event_type=event_type,
        partition_id=partition_id,
        offset=str(event.offset),
        sequence_number=int(event.sequence_number) if event.sequence_number is not None else 0,
        enqueued_time=enqueued_time,
        received_time=received_time,
    )

    # upsert (not create_item) for at-least-once idempotency: a
    # redelivered event lands on the same id and is silently overwritten
    # rather than 409'ing. Trade-off documented in the slice commit.
    # Errors propagate so the EH trigger's default retry kicks in.
    _get_container().upsert_item(doc)
