import json
import logging
from unittest.mock import MagicMock

import pytest

import function_app
from function_app import telemetry_writer


def _event(body: bytes, properties: dict | None = None,
           offset: str = "0", seq: int = 1,
           enqueued_time=None, sys_props=None) -> MagicMock:
    e = MagicMock()
    e.get_body.return_value = body
    e.offset = offset
    e.sequence_number = seq
    e.partition_key = None
    e.enqueued_time = enqueued_time
    md = {"Properties": properties or {}}
    if sys_props is not None:
        md["SystemPropertiesArray"] = sys_props
    e.metadata = md
    return e


@pytest.fixture(autouse=True)
def _stub_container(monkeypatch):
    """Replace _get_container with a Mock so tests don't hit real Cosmos.

    autouse=True means every test gets the stub — there's no test in
    this suite that wants the real client.
    """
    container = MagicMock()
    monkeypatch.setattr(function_app, "_get_container", lambda: container)
    monkeypatch.setattr(function_app, "_container_client", container)
    return container


def _records(caplog) -> list[logging.LogRecord]:
    return [r for r in caplog.records if r.getMessage().startswith("event_received")]


def test_logs_and_upserts_valid_event(caplog, _stub_container):
    caplog.set_level(logging.INFO)
    body = json.dumps({"device_id": "sim-01", "ts": "2026-04-26T12:00:00Z"}).encode()
    telemetry_writer(_event(body, properties={"eventType": "telemetry"},
                            offset="42", seq=7))

    records = _records(caplog)
    assert len(records) == 1
    msg = records[0].getMessage()
    assert "device_id=sim-01" in msg
    assert "event_type=telemetry" in msg
    assert "offset=42" in msg
    assert "seq=7" in msg

    _stub_container.upsert_item.assert_called_once()
    doc = _stub_container.upsert_item.call_args.args[0]
    assert doc["id"] == "0-42"
    assert doc["device_id"] == "sim-01"
    assert doc["event_type"] == "telemetry"
    assert doc["offset"] == "42"
    assert doc["sequence_number"] == 7
    assert doc["ts"] == "2026-04-26T12:00:00Z"


def test_id_is_deterministic_per_partition_offset(_stub_container):
    body = json.dumps({"device_id": "sim-02"}).encode()
    telemetry_writer(_event(body, properties={"eventType": "telemetry"},
                            offset="100", seq=1,
                            sys_props={"PartitionId": "3"}))
    doc = _stub_container.upsert_item.call_args.args[0]
    assert doc["id"] == "3-100"
    assert doc["partition_id"] == "3"


def test_malformed_body_is_dropped_not_upserted(caplog, _stub_container):
    caplog.set_level(logging.INFO)
    telemetry_writer(_event(b"not-json", properties={"eventType": "crash_suspect"}))
    assert _stub_container.upsert_item.call_count == 0
    # event_received still logs (visibility for SRE), event_dropped also logs
    msgs = [r.getMessage() for r in caplog.records]
    assert any(m.startswith("event_received") for m in msgs)
    assert any("event_dropped" in m for m in msgs)


def test_empty_body_is_dropped(_stub_container):
    telemetry_writer(_event(b"", properties={}))
    assert _stub_container.upsert_item.call_count == 0


def test_missing_metadata_does_not_raise(_stub_container):
    e = _event(b'{"device_id":"sim-01"}')
    e.metadata = None
    telemetry_writer(e)
    assert _stub_container.upsert_item.call_count == 1
    doc = _stub_container.upsert_item.call_args.args[0]
    assert doc["device_id"] == "sim-01"
    assert doc["event_type"] == ""


def test_body_device_id_collision_with_event_metadata(_stub_container):
    # Body has a 'partition_id' field of its own — the writer overrides
    # it with the actual EH partition_id. This is intentional: the
    # producer's notion of partition_id (if any) is meaningless; the
    # consumer-side partition ownership is the source of truth.
    body = json.dumps({"device_id": "sim-01", "partition_id": "fake"}).encode()
    telemetry_writer(_event(body, properties={"eventType": "telemetry"},
                            sys_props={"PartitionId": "2"}))
    doc = _stub_container.upsert_item.call_args.args[0]
    assert doc["partition_id"] == "2"
