import json
import logging
from datetime import datetime, timezone
from unittest.mock import MagicMock, call

import pytest

import function_app
from function_app import classify_crash


_CRASH_TS = "2026-04-27T14:32:00.000000"
_DEVICE_ID = "sim-01"


def _event(body: bytes, event_type: str = "crash_suspect") -> MagicMock:
    e = MagicMock()
    e.get_body.return_value = body
    e.offset = "55"
    e.sequence_number = 3
    e.partition_key = None
    e.enqueued_time = datetime(2026, 4, 27, 14, 32, 0, tzinfo=timezone.utc)
    e.metadata = {"Properties": {"eventType": event_type}}
    return e


def _crash_body(device_id: str = _DEVICE_ID, timestamp: str = _CRASH_TS) -> bytes:
    return json.dumps({"device_id": device_id, "timestamp": timestamp}).encode()


@pytest.fixture(autouse=True)
def _stub_clients(monkeypatch):
    """Patch all Azure SDK clients so tests never reach real services."""
    cosmos = MagicMock()
    cosmos.query_items.return_value = [
        {"device_id": _DEVICE_ID, "timestamp": "2026-04-27T14:31:50", "event_type": "telemetry"},
        {"device_id": _DEVICE_ID, "timestamp": "2026-04-27T14:31:55", "event_type": "telemetry"},
    ]
    sb_sender = MagicMock()

    monkeypatch.setattr(function_app, "_cosmos_container_client", cosmos)
    monkeypatch.setattr(function_app, "_get_cosmos_container", lambda: cosmos)
    monkeypatch.setattr(function_app, "_sb_sender", sb_sender)
    monkeypatch.setattr(function_app, "_get_sb_sender", lambda: sb_sender)
    # Default: ML stub returns high confidence
    monkeypatch.setattr(function_app, "_call_ml", lambda _window: {"is_crash": True, "confidence": 0.95})

    return cosmos, sb_sender


# ---------------------------------------------------------------------------
# Skip logic
# ---------------------------------------------------------------------------

def test_non_crash_event_is_skipped(_stub_clients, caplog):
    cosmos, sb_sender = _stub_clients
    caplog.set_level(logging.INFO)

    classify_crash(_event(_crash_body(), event_type="telemetry"))

    cosmos.query_items.assert_not_called()
    sb_sender.send_messages.assert_not_called()


def test_missing_device_id_is_dropped(_stub_clients, caplog):
    cosmos, sb_sender = _stub_clients
    caplog.set_level(logging.WARNING)

    body = json.dumps({"timestamp": _CRASH_TS}).encode()
    classify_crash(_event(body))

    cosmos.query_items.assert_not_called()
    sb_sender.send_messages.assert_not_called()
    assert any("event_dropped" in r.getMessage() for r in caplog.records)


def test_missing_timestamp_is_dropped(_stub_clients, caplog):
    cosmos, sb_sender = _stub_clients
    caplog.set_level(logging.WARNING)

    body = json.dumps({"device_id": _DEVICE_ID}).encode()
    classify_crash(_event(body))

    cosmos.query_items.assert_not_called()
    sb_sender.send_messages.assert_not_called()
    assert any("event_dropped" in r.getMessage() for r in caplog.records)


def test_malformed_body_is_dropped(_stub_clients, caplog):
    cosmos, sb_sender = _stub_clients
    caplog.set_level(logging.WARNING)

    classify_crash(_event(b"not-json"))

    cosmos.query_items.assert_not_called()
    sb_sender.send_messages.assert_not_called()


# ---------------------------------------------------------------------------
# Telemetry window fetch
# ---------------------------------------------------------------------------

def test_cosmos_query_uses_device_id_and_time_range(_stub_clients):
    cosmos, _ = _stub_clients

    classify_crash(_event(_crash_body()))

    cosmos.query_items.assert_called_once()
    kwargs = cosmos.query_items.call_args.kwargs
    params = {p["name"]: p["value"] for p in kwargs["parameters"]}
    assert params["@device_id"] == _DEVICE_ID
    assert params["@end_time"] == _CRASH_TS
    # start is 30s before crash
    assert params["@start_time"] < _CRASH_TS
    assert kwargs.get("partition_key") == _DEVICE_ID


# ---------------------------------------------------------------------------
# Below-threshold path
# ---------------------------------------------------------------------------

def test_below_threshold_does_not_publish(monkeypatch, _stub_clients, caplog):
    _, sb_sender = _stub_clients
    monkeypatch.setattr(function_app, "_call_ml", lambda _: {"is_crash": False, "confidence": 0.5})
    caplog.set_level(logging.INFO)

    classify_crash(_event(_crash_body()))

    sb_sender.send_messages.assert_not_called()


def test_below_threshold_logs_custom_event(monkeypatch, _stub_clients, caplog):
    monkeypatch.setattr(function_app, "_call_ml", lambda _: {"is_crash": False, "confidence": 0.5})
    caplog.set_level(logging.INFO)

    classify_crash(_event(_crash_body()))

    msgs = [r.getMessage() for r in caplog.records]
    assert any("crash_below_threshold" in m for m in msgs)
    assert any("device_id=sim-01" in m for m in msgs)
    assert any("confidence=0.500" in m for m in msgs)


# ---------------------------------------------------------------------------
# Above-threshold path
# ---------------------------------------------------------------------------

def test_above_threshold_publishes_to_service_bus(_stub_clients):
    _, sb_sender = _stub_clients

    classify_crash(_event(_crash_body()))

    sb_sender.send_messages.assert_called_once()


def test_published_message_contains_device_id_and_confidence(_stub_clients):
    _, sb_sender = _stub_clients

    classify_crash(_event(_crash_body()))

    msg = sb_sender.send_messages.call_args.args[0]
    payload = json.loads(b"".join(msg.body))
    assert payload["device_id"] == _DEVICE_ID
    assert payload["confidence"] == pytest.approx(0.95)
    assert payload["crash_timestamp"] == _CRASH_TS


def test_published_message_id_is_deterministic(_stub_clients):
    _, sb_sender = _stub_clients

    classify_crash(_event(_crash_body()))

    msg = sb_sender.send_messages.call_args.args[0]
    assert msg.message_id == f"{_DEVICE_ID}|{_CRASH_TS}"


def test_published_message_id_differs_for_different_devices(monkeypatch, _stub_clients):
    cosmos, sb_sender = _stub_clients

    classify_crash(_event(_crash_body(device_id="sim-02")))
    msg = sb_sender.send_messages.call_args.args[0]
    assert "sim-02" in msg.message_id
    assert "sim-01" not in msg.message_id


def test_above_threshold_logs_confirmation(_stub_clients, caplog):
    caplog.set_level(logging.INFO)

    classify_crash(_event(_crash_body()))

    msgs = [r.getMessage() for r in caplog.records]
    assert any("crash_confirmed_published" in m for m in msgs)
    assert any("device_id=sim-01" in m for m in msgs)
