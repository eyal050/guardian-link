from __future__ import annotations

import json
import logging

import azure.functions as func


app = func.FunctionApp()


@app.event_hub_message_trigger(
    arg_name="event",
    event_hub_name="telemetry",
    connection="EH_TELEMETRY",
    consumer_group="metrics",
)
def record_throughput(event: func.EventHubEvent) -> None:
    properties = (event.metadata or {}).get("Properties") or {}
    event_type = str(properties.get("eventType", "unknown"))
    body = {}
    try:
        body = json.loads(event.get_body().decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        pass
    logging.info(
        "telemetry_event_received event_type=%s device_id=%s seq=%s",
        event_type,
        body.get("device_id", ""),
        event.sequence_number,
    )
