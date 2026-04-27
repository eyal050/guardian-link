import json
import logging
from unittest.mock import MagicMock

import pytest


def _event(body: bytes = b"", event_type: str = "telemetry", seq: int = 1) -> MagicMock:
    e = MagicMock()
    e.get_body.return_value = body
    e.sequence_number = seq
    e.metadata = {"Properties": {"eventType": event_type}}
    return e


def test_happy_path_logs_event_type_and_device_id(caplog):
    """Valid event with eventType property and JSON body → correct log line."""
    from function_app import record_throughput

    body = json.dumps({"device_id": "sim-01", "value": 1.5}).encode()
    event = _event(body=body, event_type="telemetry", seq=42)
    caplog.set_level(logging.INFO)

    record_throughput(event)

    msgs = [r.getMessage() for r in caplog.records]
    assert any("telemetry_event_received" in m for m in msgs)
    assert any("event_type=telemetry" in m for m in msgs)
    assert any("device_id=sim-01" in m for m in msgs)


def test_unknown_event_type_logs_unknown(caplog):
    """No Properties in metadata → event_type=unknown, no exception."""
    from function_app import record_throughput

    event = MagicMock()
    event.get_body.return_value = b"{}"
    event.sequence_number = 1
    event.metadata = {}        # no Properties key
    caplog.set_level(logging.INFO)

    record_throughput(event)

    msgs = [r.getMessage() for r in caplog.records]
    assert any("event_type=unknown" in m for m in msgs)


def test_malformed_body_logs_with_empty_device_id(caplog):
    """Non-JSON body → logs with empty device_id, no exception raised."""
    from function_app import record_throughput

    event = _event(body=b"not-json", event_type="telemetry")
    caplog.set_level(logging.INFO)

    record_throughput(event)

    msgs = [r.getMessage() for r in caplog.records]
    assert any("telemetry_event_received" in m for m in msgs)
    # device_id= with empty string value means the field is present
    assert any("device_id=" in m for m in msgs)
