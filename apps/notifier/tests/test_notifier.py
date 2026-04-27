import json
from unittest.mock import MagicMock

import pytest

import function_app
from function_app import notify_crash


_DEVICE_ID = "sim-01"
_CRASH_TS = "2026-04-27T14:32:00.000000"
_MSG_ID = f"{_DEVICE_ID}|{_CRASH_TS}"


def _msg(device_id=_DEVICE_ID, crash_timestamp=_CRASH_TS, confidence=0.95):
    m = MagicMock()
    m.get_body.return_value = json.dumps({
        "device_id": device_id,
        "crash_timestamp": crash_timestamp,
        "confidence": confidence,
        "classifier_version": "stub-v1",
    }).encode()
    return m


def _completed_record():
    return {
        "id": _MSG_ID,
        "device_id": _DEVICE_ID,
        "crash_timestamp": _CRASH_TS,
        "confidence": 0.95,
        "status": "completed",
        "channels_completed": ["sms", "email", "push"],
        "channels_failed": [],
        "created_at": "2026-04-27T14:32:01Z",
        "completed_at": "2026-04-27T14:32:05Z",
    }


def _in_flight_record(channels_completed=None):
    return {
        "id": _MSG_ID,
        "device_id": _DEVICE_ID,
        "crash_timestamp": _CRASH_TS,
        "confidence": 0.95,
        "status": "in_flight",
        "channels_completed": channels_completed or [],
        "channels_failed": [],
        "created_at": "2026-04-27T14:32:01Z",
        "completed_at": None,
    }


def _contacts():
    return [
        {
            "contact_id": "00000000-0000-0000-0000-000000000001",
            "name": "Alice",
            "phone": "+31600000000",
            "email": "alice@example.com",
            "push_token": None,
        }
    ]


@pytest.fixture(autouse=True)
def _stub_all(monkeypatch):
    """Stub all external calls. Individual tests override as needed."""
    container = MagicMock()

    sms_client = MagicMock()
    email_client = MagicMock()
    poller = MagicMock()
    email_client.begin_send.return_value = poller

    monkeypatch.setenv("ACS_SENDER_PHONE", "+31600000000")
    monkeypatch.setenv("ACS_SENDER_EMAIL", "donotreply@test.azurecomm.net")

    monkeypatch.setattr(function_app, "_get_cosmos_container", lambda: container)
    monkeypatch.setattr(function_app, "_get_notification_record",
                        lambda c, m, d: None)
    monkeypatch.setattr(function_app, "_upsert_notification_record",
                        MagicMock())
    monkeypatch.setattr(function_app, "_get_contacts",
                        lambda device_id: _contacts())
    monkeypatch.setattr(function_app, "_get_sms_client", lambda: sms_client)
    monkeypatch.setattr(function_app, "_get_email_client", lambda: email_client)

    return {
        "container": container,
        "sms_client": sms_client,
        "email_client": email_client,
    }


# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------

def test_idempotency_completed_skips_all_calls(_stub_all, monkeypatch):
    """Cosmos returns completed → zero ACS and Postgres calls."""
    mock_get_contacts = MagicMock()
    monkeypatch.setattr(function_app, "_get_notification_record",
                        lambda c, m, d: _completed_record())
    monkeypatch.setattr(function_app, "_get_contacts", mock_get_contacts)

    notify_crash(_msg())

    mock_get_contacts.assert_not_called()
    _stub_all["sms_client"].send.assert_not_called()
    _stub_all["email_client"].begin_send.assert_not_called()


# ---------------------------------------------------------------------------
# Resume from partial delivery
# ---------------------------------------------------------------------------

def test_resume_skips_sms_when_already_completed(_stub_all, monkeypatch):
    """On redeliver with channels_completed=['sms'], SMS is not called again."""
    monkeypatch.setattr(function_app, "_get_notification_record",
                        lambda c, m, d: _in_flight_record(channels_completed=["sms"]))

    notify_crash(_msg())

    _stub_all["sms_client"].send.assert_not_called()
    _stub_all["email_client"].begin_send.assert_called_once()


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

def test_happy_path_calls_sms_and_email(_stub_all):
    """No existing record → SMS and email both called."""
    notify_crash(_msg())

    _stub_all["sms_client"].send.assert_called_once()
    _stub_all["email_client"].begin_send.assert_called_once()


def test_happy_path_marks_cosmos_completed(_stub_all, monkeypatch):
    """After successful fan-out, Cosmos record is updated to completed."""
    upsert_calls = []
    monkeypatch.setattr(function_app, "_upsert_notification_record",
                        lambda container, record: upsert_calls.append(record))

    notify_crash(_msg())

    final = upsert_calls[-1]
    assert final["status"] == "completed"
    assert final["completed_at"] is not None
    assert set(final["channels_completed"]) >= {"sms", "email", "push"}


# ---------------------------------------------------------------------------
# Channel failure propagates
# ---------------------------------------------------------------------------

def test_sms_failure_propagates(_stub_all):
    """ACS SMS raises → exception propagates (SB will redeliver)."""
    _stub_all["sms_client"].send.side_effect = RuntimeError("ACS unreachable")

    with pytest.raises(RuntimeError, match="ACS unreachable"):
        notify_crash(_msg())


# ---------------------------------------------------------------------------
# No contacts edge case
# ---------------------------------------------------------------------------

def test_no_contacts_marks_completed_without_sending(_stub_all, monkeypatch, caplog):
    """No contacts → log warning, mark completed, no ACS calls."""
    import logging
    monkeypatch.setattr(function_app, "_get_contacts", lambda d: [])
    caplog.set_level(logging.WARNING)

    notify_crash(_msg())

    _stub_all["sms_client"].send.assert_not_called()
    _stub_all["email_client"].begin_send.assert_not_called()
    assert any("no_contacts_found" in r.getMessage() for r in caplog.records)
