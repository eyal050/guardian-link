import json

import pytest

from fleet import load_roster


def _write(tmp_path, data):
    p = tmp_path / "devices.json"
    p.write_text(data if isinstance(data, str) else json.dumps(data))
    return p


def test_load_roster_valid(tmp_path):
    roster = [
        {"id": "sim-01", "telemetry_period_s": 20, "crash_period_s": 120},
        {"id": "sim-02", "telemetry_period_s": 27, "crash_period_s": 95},
    ]
    assert load_roster(_write(tmp_path, roster)) == roster


def test_load_roster_missing_file(tmp_path):
    with pytest.raises(SystemExit):
        load_roster(tmp_path / "nope.json")


def test_load_roster_not_a_list(tmp_path):
    with pytest.raises(SystemExit):
        load_roster(_write(tmp_path, {"id": "sim-01"}))


def test_load_roster_empty(tmp_path):
    with pytest.raises(SystemExit):
        load_roster(_write(tmp_path, []))


def test_load_roster_missing_keys(tmp_path):
    with pytest.raises(SystemExit):
        load_roster(_write(tmp_path, [{"id": "sim-01", "telemetry_period_s": 20}]))


def test_load_roster_duplicate_ids(tmp_path):
    dupes = [
        {"id": "sim-01", "telemetry_period_s": 20, "crash_period_s": 120},
        {"id": "sim-01", "telemetry_period_s": 27, "crash_period_s": 95},
    ]
    with pytest.raises(SystemExit):
        load_roster(_write(tmp_path, dupes))


def test_load_roster_bad_json(tmp_path):
    with pytest.raises(SystemExit):
        load_roster(_write(tmp_path, "{not json"))
