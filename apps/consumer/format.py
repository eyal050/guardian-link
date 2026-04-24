"""Pure function: turn an Event Hub event into a human-readable line."""

from __future__ import annotations

from datetime import datetime


def _fmt_accel(accel: dict | None) -> str:
    if not accel:
        return "?"
    x = accel.get("x", "?")
    y = accel.get("y", "?")
    z = accel.get("z", "?")
    return f"({x},{y},{z})"


def format_event(
    body: dict,
    event_type: str,
    partition_id: str,
    enqueued_time: datetime,
) -> str:
    device_id = body.get("device_id", "?")
    hr = body.get("heart_rate_bpm", "?")
    battery = body.get("battery_pct", "?")
    accel = _fmt_accel(body.get("accelerometer"))
    conf = body.get("suspect_confidence")
    ts = enqueued_time.isoformat() if enqueued_time is not None else "?"

    tail = f"HR={hr} bat={battery} accel={accel}"
    if conf is not None:
        tail = f"conf={conf} " + tail

    return f"[p={partition_id} {event_type} {device_id} @ {ts}] {tail}"
