"""Async Event Hub consumer: reads from the 'inspector' consumer group,
formats each event to stdout, logs to App Insights 'traces'. A Blob-
backed checkpoint store records per-partition offsets so multiple
instances in the same consumer group cooperate on partition ownership
(load balance) instead of each draining all 4 partitions independently.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import signal

from azure.eventhub.aio import EventHubConsumerClient
from azure.eventhub.extensions.checkpointstoreblobaio import BlobCheckpointStore
from azure.identity.aio import DefaultAzureCredential
from azure.monitor.opentelemetry import configure_azure_monitor
from dotenv import load_dotenv

from format import format_event


log = logging.getLogger("consumer")


def _configure() -> dict:
    load_dotenv()
    required = [
        "EVENT_HUB_FQDN",
        "EVENT_HUB_NAME",
        "CONSUMER_GROUP",
        "APPLICATIONINSIGHTS_CONNECTION_STRING",
        "STORAGE_BLOB_ACCOUNT_URL",
        "CHECKPOINT_CONTAINER",
    ]
    missing = [k for k in required if not os.environ.get(k)]
    if missing:
        raise SystemExit(f"missing env vars: {missing}. run bootstrap.py first.")
    # basicConfig BEFORE configure_azure_monitor (same lesson as simulator).
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    configure_azure_monitor(
        connection_string=os.environ["APPLICATIONINSIGHTS_CONNECTION_STRING"],
    )
    return {
        "fqdn": os.environ["EVENT_HUB_FQDN"],
        "hub": os.environ["EVENT_HUB_NAME"],
        "cg": os.environ["CONSUMER_GROUP"],
        "starting": os.environ.get("STARTING_POSITION", "@latest"),
        "blob_url": os.environ["STORAGE_BLOB_ACCOUNT_URL"],
        "container": os.environ["CHECKPOINT_CONTAINER"],
    }


async def _on_event(partition_context, event) -> None:
    try:
        raw = event.body_as_str()
        body = json.loads(raw) if raw else {}
        event_type_bytes = (event.properties or {}).get(b"eventType", b"")
        event_type = (
            event_type_bytes.decode()
            if isinstance(event_type_bytes, bytes)
            else str(event_type_bytes)
        )
        line = format_event(
            body=body,
            event_type=event_type,
            partition_id=partition_context.partition_id,
            enqueued_time=event.enqueued_time,
        )
        print(line, flush=True)
        log.info(
            "message_received",
            extra={
                "event_type": event_type,
                "partition_id": partition_context.partition_id,
                "device_id": body.get("device_id", ""),
            },
        )
    except Exception as e:  # noqa: BLE001 - keep the pump alive
        log.warning(
            "message_decode_failed",
            extra={"partition_id": partition_context.partition_id, "error": repr(e)},
        )
    # Checkpoint per event. At dev volumes (~3 msg/min) the storage cost
    # is trivial; at higher throughput, switch to a count- or time-based
    # batch (every N events / every T seconds).
    await partition_context.update_checkpoint(event)


async def _run() -> None:
    cfg = _configure()
    credential = DefaultAzureCredential()
    # Same credential drives both clients: one principal, two RBAC roles
    # (Event Hubs Data Receiver on the hub, Storage Blob Data Contributor
    # on the checkpoint container).
    checkpoint_store = BlobCheckpointStore(
        blob_account_url=cfg["blob_url"],
        container_name=cfg["container"],
        credential=credential,
    )
    client = EventHubConsumerClient(
        fully_qualified_namespace=cfg["fqdn"],
        eventhub_name=cfg["hub"],
        consumer_group=cfg["cg"],
        credential=credential,
        checkpoint_store=checkpoint_store,
    )
    log.info("consumer_started", extra={"consumer_group": cfg["cg"]})
    print(
        f"consuming from {cfg['fqdn']}/{cfg['hub']} (cg={cfg['cg']}, starting={cfg['starting']})",
        flush=True,
    )

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_event.set)

    receive_task = asyncio.create_task(
        client.receive(on_event=_on_event, starting_position=cfg["starting"])
    )
    await stop_event.wait()
    log.info("shutting down")

    receive_task.cancel()
    try:
        await receive_task
    except asyncio.CancelledError:
        pass
    await client.close()
    await checkpoint_store.close()
    await credential.close()


def main() -> None:
    asyncio.run(_run())


if __name__ == "__main__":
    main()
