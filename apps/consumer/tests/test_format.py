from datetime import datetime, timezone

from format import format_event


T = datetime(2026, 4, 24, 19, 49, 13, tzinfo=timezone.utc)


def _telemetry_body() -> dict:
    return {
        "device_id": "sim-01",
        "timestamp": T.isoformat(),
        "accelerometer": {"x": 0.12, "y": -0.05, "z": 0.98},
        "gps": {"lat": 52.3676, "lon": 4.9041},
        "battery_pct": 87.2,
        "heart_rate_bpm": 73,
        "suspect_confidence": None,
    }


def _crash_body() -> dict:
    return {
        "device_id": "sim-01",
        "timestamp": T.isoformat(),
        "accelerometer": {"x": 0.1, "y": 8.2, "z": -0.3},
        "gps": {"lat": 52.3676, "lon": 4.9041},
        "battery_pct": 80.0,
        "heart_rate_bpm": 150,
        "suspect_confidence": 0.65,
    }


def test_telemetry_format_includes_core_fields():
    s = format_event(_telemetry_body(), "telemetry", "2", T)
    assert "telemetry" in s
    assert "sim-01" in s
    assert "p=2" in s
    assert "HR=73" in s
    assert "bat=87.2" in s
    assert "accel=(0.12,-0.05,0.98)" in s
    assert "conf=" not in s


def test_crash_suspect_includes_confidence():
    s = format_event(_crash_body(), "crash_suspect", "1", T)
    assert "crash_suspect" in s
    assert "conf=0.65" in s
    assert "HR=150" in s


def test_missing_fields_tolerated():
    s = format_event({}, "", "0", T)
    assert "p=0" in s


def test_enqueued_time_iso_formatted():
    s = format_event(_telemetry_body(), "telemetry", "0", T)
    assert "2026-04-24T19:49:13" in s
