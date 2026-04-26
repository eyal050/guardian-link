import json
import logging
from unittest.mock import MagicMock

from function_app import telemetry_writer


def _event(body: bytes, properties: dict | None = None,
           offset: str = "0", seq: int = 1) -> MagicMock:
    e = MagicMock()
    e.get_body.return_value = body
    e.offset = offset
    e.sequence_number = seq
    e.metadata = {"Properties": properties or {}}
    return e


def _records(caplog) -> list[logging.LogRecord]:
    return [r for r in caplog.records if r.getMessage().startswith("event_received")]


def test_parses_valid_body_and_logs_extras(caplog):
    caplog.set_level(logging.INFO)
    body = json.dumps({"device_id": "sim-01", "ts": "2026-04-25T12:00:00Z"}).encode()
    telemetry_writer(_event(body, properties={"eventType": "telemetry"}))
    records = _records(caplog)
    assert len(records) == 1
    msg = records[0].getMessage()
    assert "device_id=sim-01" in msg
    assert "event_type=telemetry" in msg
    assert "offset=0" in msg
    assert "seq=1" in msg


def test_handles_malformed_body_without_raising(caplog):
    caplog.set_level(logging.INFO)
    telemetry_writer(_event(b"not-json", properties={"eventType": "crash_suspect"}))
    records = _records(caplog)
    assert len(records) == 1
    msg = records[0].getMessage()
    # device_id falls back to "" when the body is unparseable, but
    # eventType (which lives in the message envelope, not the body)
    # is still logged — that distinction matters when triaging.
    assert "device_id=" in msg and "device_id=sim-" not in msg
    assert "event_type=crash_suspect" in msg


def test_handles_empty_body(caplog):
    caplog.set_level(logging.INFO)
    telemetry_writer(_event(b"", properties={}))
    records = _records(caplog)
    assert len(records) == 1


def test_missing_metadata_does_not_raise(caplog):
    caplog.set_level(logging.INFO)
    e = _event(b'{"device_id":"sim-01"}')
    e.metadata = None
    telemetry_writer(e)
    records = _records(caplog)
    assert len(records) == 1
    msg = records[0].getMessage()
    assert "device_id=sim-01" in msg
    assert "event_type=" in msg
