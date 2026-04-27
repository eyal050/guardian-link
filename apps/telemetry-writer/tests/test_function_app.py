import json
import logging
from datetime import datetime, timezone
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
    # Default to a fixed UTC time so blob-name partitioning is deterministic
    # in tests that don't pass their own.
    e.enqueued_time = enqueued_time or datetime(2026, 4, 26, 12, 30, 0, tzinfo=timezone.utc)
    md = {"Properties": properties or {}}
    if sys_props is not None:
        md["SystemPropertiesArray"] = sys_props
    e.metadata = md
    return e


@pytest.fixture(autouse=True)
def _stub_clients(monkeypatch):
    """Replace Cosmos + Blob clients with Mocks so tests don't hit real Azure.

    autouse=True means every test gets the stubs — there's no test in
    this suite that wants the real clients.
    """
    container = MagicMock()
    blob_container = MagicMock()
    monkeypatch.setattr(function_app, "_get_container", lambda: container)
    monkeypatch.setattr(function_app, "_container_client", container)
    monkeypatch.setattr(function_app, "_get_blob_container", lambda: blob_container)
    monkeypatch.setattr(function_app, "_blob_container_client", blob_container)
    return container, blob_container


def _records(caplog) -> list[logging.LogRecord]:
    return [r for r in caplog.records if r.getMessage().startswith("event_received")]


def test_logs_and_upserts_valid_event(caplog, _stub_clients):
    container, blob_container = _stub_clients
    caplog.set_level(logging.INFO)
    body = json.dumps({"device_id": "sim-01", "ts": "2026-04-26T12:00:00Z"}).encode()
    telemetry_writer([_event(body, properties={"eventType": "telemetry"},
                             offset="42", seq=7)])

    records = _records(caplog)
    assert len(records) == 1
    msg = records[0].getMessage()
    assert "device_id=sim-01" in msg
    assert "event_type=telemetry" in msg
    assert "offset=42" in msg
    assert "seq=7" in msg

    container.upsert_item.assert_called_once()
    doc = container.upsert_item.call_args.args[0]
    assert doc["id"] == "0-42"
    assert doc["device_id"] == "sim-01"
    assert doc["event_type"] == "telemetry"
    assert doc["offset"] == "42"
    assert doc["sequence_number"] == 7
    assert doc["ts"] == "2026-04-26T12:00:00Z"

    # Single-event batch still produces one blob, name encodes the
    # offset range (start == end == "42") and the hour bucket.
    blob_container.upload_blob.assert_called_once()
    kwargs = blob_container.upload_blob.call_args.kwargs
    assert kwargs["overwrite"] is True
    assert kwargs["name"] == "events/year=2026/month=04/day=26/hour=12/p0-42-42.ndjson"
    # NDJSON body: one line, decodes back to the upserted doc.
    body_bytes = kwargs["data"]
    lines = body_bytes.decode("utf-8").rstrip("\n").split("\n")
    assert len(lines) == 1
    assert json.loads(lines[0])["id"] == "0-42"


def test_id_is_deterministic_per_partition_offset(_stub_clients):
    container, blob_container = _stub_clients
    body = json.dumps({"device_id": "sim-02"}).encode()
    telemetry_writer([_event(body, properties={"eventType": "telemetry"},
                             offset="100", seq=1,
                             sys_props={"PartitionId": "3"})])
    doc = container.upsert_item.call_args.args[0]
    assert doc["id"] == "3-100"
    assert doc["partition_id"] == "3"
    # Blob name picks up the same partition id.
    assert "p3-100-100" in blob_container.upload_blob.call_args.kwargs["name"]


def test_malformed_body_is_dropped_not_upserted(caplog, _stub_clients):
    container, blob_container = _stub_clients
    caplog.set_level(logging.INFO)
    telemetry_writer([_event(b"not-json", properties={"eventType": "crash_suspect"})])
    assert container.upsert_item.call_count == 0
    # event_received still logs (visibility for SRE), event_dropped also logs
    msgs = [r.getMessage() for r in caplog.records]
    assert any(m.startswith("event_received") for m in msgs)
    assert any("event_dropped" in m for m in msgs)
    # No valid documents → no blob written.
    assert blob_container.upload_blob.call_count == 0


def test_empty_body_is_dropped(_stub_clients):
    container, blob_container = _stub_clients
    telemetry_writer([_event(b"", properties={})])
    assert container.upsert_item.call_count == 0
    assert blob_container.upload_blob.call_count == 0


def test_missing_metadata_does_not_raise(_stub_clients):
    container, blob_container = _stub_clients
    e = _event(b'{"device_id":"sim-01"}')
    e.metadata = None
    telemetry_writer([e])
    assert container.upsert_item.call_count == 1
    doc = container.upsert_item.call_args.args[0]
    assert doc["device_id"] == "sim-01"
    assert doc["event_type"] == ""
    assert blob_container.upload_blob.call_count == 1


def test_body_device_id_collision_with_event_metadata(_stub_clients):
    container, _ = _stub_clients
    # Body has a 'partition_id' field of its own — the writer overrides
    # it with the actual EH partition_id. This is intentional: the
    # producer's notion of partition_id (if any) is meaningless; the
    # consumer-side partition ownership is the source of truth.
    body = json.dumps({"device_id": "sim-01", "partition_id": "fake"}).encode()
    telemetry_writer([_event(body, properties={"eventType": "telemetry"},
                             sys_props={"PartitionId": "2"})])
    doc = container.upsert_item.call_args.args[0]
    assert doc["partition_id"] == "2"


def test_batch_writes_one_blob_with_one_line_per_valid_event(_stub_clients):
    container, blob_container = _stub_clients
    events = [
        _event(json.dumps({"device_id": "sim-01"}).encode(),
               properties={"eventType": "telemetry"},
               offset="100", seq=10,
               sys_props={"PartitionId": "1"}),
        _event(json.dumps({"device_id": "sim-02"}).encode(),
               properties={"eventType": "telemetry"},
               offset="101", seq=11,
               sys_props={"PartitionId": "1"}),
        _event(json.dumps({"device_id": "sim-03"}).encode(),
               properties={"eventType": "crash_suspect"},
               offset="102", seq=12,
               sys_props={"PartitionId": "1"}),
    ]
    telemetry_writer(events)

    # Three Cosmos upserts, one blob with three NDJSON lines.
    assert container.upsert_item.call_count == 3
    blob_container.upload_blob.assert_called_once()
    kwargs = blob_container.upload_blob.call_args.kwargs
    # Blob name spans the whole offset range from first to last event.
    assert kwargs["name"].endswith("p1-100-102.ndjson")
    lines = kwargs["data"].decode("utf-8").rstrip("\n").split("\n")
    assert len(lines) == 3
    parsed = [json.loads(line) for line in lines]
    assert [d["id"] for d in parsed] == ["1-100", "1-101", "1-102"]


def test_batch_with_one_dropped_event_archives_only_valid_ones(_stub_clients):
    container, blob_container = _stub_clients
    events = [
        _event(json.dumps({"device_id": "sim-01"}).encode(),
               properties={"eventType": "telemetry"},
               offset="200", seq=20,
               sys_props={"PartitionId": "0"}),
        # No device_id → dropped, not in blob, not in Cosmos.
        _event(json.dumps({"foo": "bar"}).encode(),
               properties={"eventType": "telemetry"},
               offset="201", seq=21,
               sys_props={"PartitionId": "0"}),
        _event(json.dumps({"device_id": "sim-02"}).encode(),
               properties={"eventType": "telemetry"},
               offset="202", seq=22,
               sys_props={"PartitionId": "0"}),
    ]
    telemetry_writer(events)

    assert container.upsert_item.call_count == 2
    kwargs = blob_container.upload_blob.call_args.kwargs
    # Offset range still spans the full batch — that's the determinism
    # contract for blob names. The body has only the valid documents.
    assert kwargs["name"].endswith("p0-200-202.ndjson")
    lines = kwargs["data"].decode("utf-8").rstrip("\n").split("\n")
    assert len(lines) == 2
    assert [json.loads(line)["id"] for line in lines] == ["0-200", "0-202"]


def test_empty_batch_does_nothing(_stub_clients):
    container, blob_container = _stub_clients
    telemetry_writer([])
    assert container.upsert_item.call_count == 0
    assert blob_container.upload_blob.call_count == 0


def test_all_dropped_batch_skips_blob(caplog, _stub_clients):
    container, blob_container = _stub_clients
    caplog.set_level(logging.INFO)
    events = [
        _event(b"not-json", properties={"eventType": "telemetry"}),
        _event(b"", properties={"eventType": "telemetry"}),
    ]
    telemetry_writer(events)
    assert container.upsert_item.call_count == 0
    assert blob_container.upload_blob.call_count == 0
    msgs = [r.getMessage() for r in caplog.records]
    assert any("batch_archive_skipped" in m for m in msgs)
