import logging
from datetime import datetime, timezone
from unittest.mock import MagicMock

import pytest

import function_app
from function_app import _log_notification_latency


_COMPLETED_AT = "2026-04-27T14:32:05.000000+00:00"
_SB_ENQUEUED = datetime(2026, 4, 27, 14, 32, 3, tzinfo=timezone.utc)
_EH_ENQUEUED = "2026-04-27T14:32:00+00:00"


def _msg(sb_enqueued=_SB_ENQUEUED):
    m = MagicMock()
    m.enqueued_time_utc = sb_enqueued
    return m


def test_both_timestamps_logs_e2e_and_stage(caplog):
    """eh_enqueued_time + sb enqueued → logs both end_to_end_ms and notification_stage_ms."""
    body = {"device_id": "sim-01", "eh_enqueued_time": _EH_ENQUEUED}
    caplog.set_level(logging.INFO)

    _log_notification_latency(_msg(), body, _COMPLETED_AT)

    msgs = [r.getMessage() for r in caplog.records]
    assert any("notification_latency" in m for m in msgs)
    assert any("end_to_end_ms=" in m for m in msgs)
    assert any("notification_stage_ms=" in m for m in msgs)


def test_only_sb_enqueued_logs_stage_only(caplog):
    """No eh_enqueued_time in body → only notification_stage_ms logged (no end_to_end_ms)."""
    body = {"device_id": "sim-01"}
    caplog.set_level(logging.INFO)

    _log_notification_latency(_msg(), body, _COMPLETED_AT)

    msgs = [r.getMessage() for r in caplog.records]
    assert any("notification_latency" in m for m in msgs)
    assert any("notification_stage_ms=" in m for m in msgs)
    assert not any("end_to_end_ms=" in m for m in msgs)


def test_no_sb_enqueued_skips_all_latency_logging(caplog):
    """msg.enqueued_time_utc=None → no latency log, warning emitted, no exception."""
    body = {"device_id": "sim-01", "eh_enqueued_time": _EH_ENQUEUED}
    caplog.set_level(logging.WARNING)

    _log_notification_latency(_msg(sb_enqueued=None), body, _COMPLETED_AT)

    msgs = [r.getMessage() for r in caplog.records]
    assert not any("notification_latency device_id" in m for m in msgs)
    assert any("notification_latency_skipped" in m for m in msgs)
