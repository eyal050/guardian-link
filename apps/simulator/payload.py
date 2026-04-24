"""Pure functions that construct simulator message payloads.

Kept free of I/O and azure-sdk imports so it's trivially unit-testable.
"""

import random
from datetime import datetime


_HOME_LAT = 52.3676
_HOME_LON = 4.9041


def _common(device_id: str, now: datetime) -> dict:
    return {
        "device_id": device_id,
        "timestamp": now.isoformat(),
        "gps": {
            "lat": _HOME_LAT + random.uniform(-0.0005, 0.0005),
            "lon": _HOME_LON + random.uniform(-0.0005, 0.0005),
        },
        "battery_pct": round(random.uniform(20.0, 100.0), 1),
    }


def build_telemetry(device_id: str, now: datetime) -> dict:
    """Plausible steady-state device reading."""
    p = _common(device_id, now)
    p["accelerometer"] = {
        "x": round(random.uniform(-1.5, 1.5), 3),
        "y": round(random.uniform(-1.5, 1.5), 3),
        "z": round(random.uniform(-1.5, 1.5), 3),
    }
    p["heart_rate_bpm"] = random.randint(60, 90)
    p["suspect_confidence"] = None
    return p


def build_crash_suspect(device_id: str, now: datetime) -> dict:
    """Reading that trips the on-device crash heuristic.

    Distinguished from telemetry only by value ranges. The IoT Hub
    custom property `eventType` (set by the caller) is what
    downstream consumers discriminate on.
    """
    p = _common(device_id, now)
    spike_axis = random.choice(["x", "y", "z"])
    accel = {axis: round(random.uniform(-1.5, 1.5), 3) for axis in ("x", "y", "z")}
    accel[spike_axis] = round(random.choice([-1, 1]) * random.uniform(3.0, 12.0), 3)
    p["accelerometer"] = accel
    p["heart_rate_bpm"] = random.randint(120, 180)
    p["suspect_confidence"] = round(random.uniform(0.4, 0.8), 3)
    return p
