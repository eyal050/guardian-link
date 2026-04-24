from datetime import datetime, timezone

import pytest

from payload import build_crash_suspect, build_telemetry


NOW = datetime(2026, 4, 24, 19, 30, 0, tzinfo=timezone.utc)
DEVICE = "sim-01"

REQUIRED_KEYS = {
    "device_id",
    "timestamp",
    "accelerometer",
    "gps",
    "battery_pct",
    "heart_rate_bpm",
    "suspect_confidence",
}


def test_telemetry_has_required_keys():
    payload = build_telemetry(DEVICE, NOW)
    assert set(payload.keys()) == REQUIRED_KEYS
    assert payload["device_id"] == DEVICE


def test_crash_suspect_has_required_keys():
    payload = build_crash_suspect(DEVICE, NOW)
    assert set(payload.keys()) == REQUIRED_KEYS
    assert payload["device_id"] == DEVICE


@pytest.mark.parametrize("i", range(100))
def test_telemetry_value_ranges(i):
    p = build_telemetry(DEVICE, NOW)
    accel = p["accelerometer"]
    assert -1.5 <= accel["x"] <= 1.5
    assert -1.5 <= accel["y"] <= 1.5
    assert -1.5 <= accel["z"] <= 1.5
    assert 52.3671 <= p["gps"]["lat"] <= 52.3681
    assert 4.9036 <= p["gps"]["lon"] <= 4.9046
    assert 20.0 <= p["battery_pct"] <= 100.0
    assert 60 <= p["heart_rate_bpm"] <= 90
    assert isinstance(p["heart_rate_bpm"], int)
    assert p["suspect_confidence"] is None


@pytest.mark.parametrize("i", range(100))
def test_crash_suspect_accelerometer_spikes(i):
    p = build_crash_suspect(DEVICE, NOW)
    accel = p["accelerometer"]
    assert max(abs(accel["x"]), abs(accel["y"]), abs(accel["z"])) >= 3.0


@pytest.mark.parametrize("i", range(100))
def test_crash_suspect_heart_rate_and_confidence(i):
    p = build_crash_suspect(DEVICE, NOW)
    assert 120 <= p["heart_rate_bpm"] <= 180
    assert 0.4 <= p["suspect_confidence"] <= 0.8


def test_timestamp_roundtrips():
    p = build_telemetry(DEVICE, NOW)
    parsed = datetime.fromisoformat(p["timestamp"])
    assert parsed == NOW
    p2 = build_crash_suspect(DEVICE, NOW)
    assert datetime.fromisoformat(p2["timestamp"]) == NOW
