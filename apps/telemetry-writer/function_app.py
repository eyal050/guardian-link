"""Telemetry-writer Function App.

Slice α: log every event to App Insights, verifying the identity-based
EH trigger fires.
Slice α+: also upsert each event into the Cosmos `telemetry` container
via DefaultAzureCredential resolving the Function App's MI.
Slice β: per-batch NDJSON archive to a separate Blob storage account.
Trigger flipped to cardinality=many so a function invocation maps to
one block-blob. Architecture decision #10.

Connection name 'EH_TELEMETRY' is supplied to the trigger by the host
via app settings EH_TELEMETRY__fullyQualifiedNamespace and
EH_TELEMETRY__credential=managedidentity (set in functions.tf).

Cosmos coordinates come from app settings COSMOS_ENDPOINT /
COSMOS_DATABASE / COSMOS_CONTAINER. Blob coordinates come from
BLOB_ARCHIVE_ACCOUNT (full primary_blob_endpoint URL) /
BLOB_ARCHIVE_CONTAINER. Both data planes are AAD-only — Cosmos
account has local_authentication_disabled=true; the writer's MI
holds 'Cosmos DB Built-in Data Contributor' and 'Storage Blob Data
Contributor' on the respective accounts.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

import azure.functions as func
from azure.cosmos import CosmosClient
from azure.functions.decorators.core import Cardinality
from azure.identity import DefaultAzureCredential

# azure.storage.blob is imported lazily inside _get_blob_container().
# Top-level import of it surfaced as "0 functions found (Custom)" on
# Linux Consumption v4: the host's worker indexer aborted silently when
# the namespace package collided with the runtime-bundled azure.* tree.
# Lazy import keeps module load light and matches the Cosmos pattern.

app = func.FunctionApp()


# Lazy module-level singletons. Constructing the SDK clients at import
# time would force every test (and any local invocation without an
# Azure context) to spin up a real credential chain. Build on first
# use inside the worker, then reuse across invocations — the Functions
# Python worker keeps the module loaded between calls.
_credential = None
_container_client = None
_blob_container_client = None


def _get_credential():  # type: ignore[no-untyped-def]
    global _credential
    if _credential is None:
        _credential = DefaultAzureCredential()
    return _credential


def _get_container():  # type: ignore[no-untyped-def]
    global _container_client
    if _container_client is None:
        client = CosmosClient(
            url=os.environ["COSMOS_ENDPOINT"],
            credential=_get_credential(),
        )
        db = client.get_database_client(os.environ["COSMOS_DATABASE"])
        _container_client = db.get_container_client(os.environ["COSMOS_CONTAINER"])
    return _container_client


def _get_blob_container():  # type: ignore[no-untyped-def]
    global _blob_container_client
    if _blob_container_client is None:
        from azure.storage.blob import BlobServiceClient

        bsc = BlobServiceClient(
            account_url=os.environ["BLOB_ARCHIVE_ACCOUNT"],
            credential=_get_credential(),
        )
        _blob_container_client = bsc.get_container_client(
            os.environ["BLOB_ARCHIVE_CONTAINER"],
        )
    return _blob_container_client


def _partition_id_of(event: func.EventHubEvent) -> str:
    """Best-effort recovery of the source partition id.

    The Functions Python worker exposes partition info inconsistently
    across runtime versions: SystemPropertiesArray is the canonical
    surface when present; partition_key is the user-supplied key (not
    the partition id) but is the only fallback.
    """
    sys_props = (event.metadata or {}).get("SystemPropertiesArray") or {}
    if isinstance(sys_props, list) and sys_props:
        pid = sys_props[0].get("PartitionId")
        if pid is not None:
            return str(pid)
    elif isinstance(sys_props, dict) and sys_props:
        pid = sys_props.get("PartitionId")
        if pid is not None:
            return str(pid)
    if event.partition_key:
        return str(event.partition_key)
    return "0"


def _build_document(
    body: dict[str, Any],
    event_type: str,
    partition_id: str,
    offset: str,
    sequence_number: int,
    enqueued_time: str,
    received_time: str,
) -> dict[str, Any]:
    """Compose the Cosmos / NDJSON document.

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


def _blob_name(
    partition_id: str,
    start_offset: str,
    end_offset: str,
    bucket_time: datetime,
) -> str:
    """Hive-style partitioned NDJSON blob path.

    `events/year=YYYY/month=MM/day=DD/hour=HH/p<partition>-<startOff>-<endOff>.ndjson`

    Offset range in the filename is the determinism contract: a
    redelivered identical batch overwrites the same blob. `bucket_time`
    is the first event's enqueued_time (UTC) — that's stable across
    retries because EH timestamps are set at producer enqueue.
    """
    return (
        f"events/year={bucket_time:%Y}/month={bucket_time:%m}/"
        f"day={bucket_time:%d}/hour={bucket_time:%H}/"
        f"p{partition_id}-{start_offset}-{end_offset}.ndjson"
    )


@app.event_hub_message_trigger(
    arg_name="events",
    event_hub_name="telemetry",
    connection="EH_TELEMETRY",
    consumer_group="telemetry-writer",
    cardinality=Cardinality.MANY,
)
def telemetry_writer(events: list[func.EventHubEvent]) -> None:
    if not events:
        return

    received_time = datetime.now(timezone.utc).isoformat()

    documents: list[dict[str, Any]] = []
    first_enqueued: datetime | None = None
    partition_id = "0"

    for event in events:
        body: dict[str, Any] = {}
        try:
            raw = event.get_body().decode("utf-8")
            if raw:
                body = json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            body = {}

        properties = (event.metadata or {}).get("Properties") or {}
        event_type = str(properties.get("eventType", ""))
        partition_id = _partition_id_of(event)

        enqueued_dt = event.enqueued_time  # tz-aware UTC datetime per SDK
        enqueued_time = str(enqueued_dt) if enqueued_dt else ""
        if first_enqueued is None and enqueued_dt is not None:
            first_enqueued = enqueued_dt

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
            continue

        doc = _build_document(
            body=body,
            event_type=event_type,
            partition_id=partition_id,
            offset=str(event.offset),
            sequence_number=int(event.sequence_number) if event.sequence_number is not None else 0,
            enqueued_time=enqueued_time,
            received_time=received_time,
        )

        # Cosmos first, Blob second. Both writes are idempotent under
        # redelivery — `id` is `<partition>-<offset>`; blob name is the
        # offset range. Errors propagate so the EH trigger's default
        # retry kicks in for the whole batch.
        _get_container().upsert_item(doc)
        documents.append(doc)

    # If every event in the batch was dropped (e.g., all malformed),
    # there's nothing to archive. Don't write an empty blob.
    if not documents:
        logging.info("batch_archive_skipped reason=no_valid_documents count=%d", len(events))
        return

    bucket_time = first_enqueued or datetime.now(timezone.utc)
    name = _blob_name(
        partition_id=partition_id,
        start_offset=str(events[0].offset),
        end_offset=str(events[-1].offset),
        bucket_time=bucket_time,
    )
    body_bytes = ("\n".join(json.dumps(d) for d in documents) + "\n").encode("utf-8")
    _get_blob_container().upload_blob(name=name, data=body_bytes, overwrite=True)

    logging.info(
        "batch_archived blob=%s events=%d documents=%d",
        name,
        len(events),
        len(documents),
    )
