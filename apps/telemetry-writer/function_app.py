"""Telemetry-writer Function App.

Slice α: Event-Hub-triggered handler that just logs each event to App
Insights, verifying the identity-based EH trigger fires end-to-end
before any storage IO is added. Blob and Cosmos writes land in
subsequent slices.

Connection name 'EH_TELEMETRY' is supplied to the trigger by the host
via app settings EH_TELEMETRY__fullyQualifiedNamespace and
EH_TELEMETRY__credential=managedidentity (set in functions.tf). The
namespace has local auth disabled, so a connection string would fail.
"""

from __future__ import annotations

import json
import logging

import azure.functions as func


app = func.FunctionApp()


@app.event_hub_message_trigger(
    arg_name="event",
    event_hub_name="telemetry",
    connection="EH_TELEMETRY",
    consumer_group="telemetry-writer",
)
def telemetry_writer(event: func.EventHubEvent) -> None:
    body: dict = {}
    try:
        raw = event.get_body().decode("utf-8")
        if raw:
            body = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        # Swallow decode/parse failures so a single poison message can't
        # halt the trigger. The empty body still produces a log line so
        # the failure is visible in App Insights.
        body = {}

    # Custom IoT Hub message properties (e.g., 'eventType' set by the
    # simulator) come through under 'Properties' in the worker metadata.
    properties = (event.metadata or {}).get("Properties") or {}

    # NOTE: the Functions Python v2 worker does NOT forward `extra=` dict
    # entries to App Insights customDimensions — only the rendered message
    # body. Embed the structured fields as named tokens in the message so
    # KQL can `parse` or `extract` them. The alternative is pulling in
    # azure-monitor-opentelemetry (as apps/consumer/ does) which propagates
    # custom dimensions natively, at the cost of an extra dependency.
    logging.info(
        "event_received device_id=%s event_type=%s offset=%s seq=%s",
        body.get("device_id", ""),
        properties.get("eventType", ""),
        event.offset,
        event.sequence_number,
    )
