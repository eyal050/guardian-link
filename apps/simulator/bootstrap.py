"""Idempotent bootstrap: register every device listed in devices.json
in the IoT Hub and persist its connection string (plus the App
Insights connection string) to a per-device .env.<id> file.

Each simulator process represents one physical device. Run
`python simulator.py --device <id>` against the matching .env.<id>
to start it.

Idempotent -- safe to re-run after `terraform destroy`/`apply` or after
adding a device to devices.json. Uses `az` CLI subprocess for both
connection-string reads so we inherit the user's `az login` without
needing separate IoT Hub data-plane RBAC grants.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from azure.iot.hub import IoTHubRegistryManager


IOTHUB_NAME = "iot-guardianlink-dev-weu"
RESOURCE_GROUP = "rg-guardianlink-dev"
APPINSIGHTS_NAME = "appi-guardianlink-dev-weu"
DEVICES_CONFIG = "devices.json"


def _az(args: list[str]) -> str:
    """Run an `az` CLI command, return stripped stdout, die loudly on failure."""
    try:
        out = subprocess.run(
            ["az", *args],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"az command failed: az {' '.join(args)}", file=sys.stderr)
        print(e.stderr, file=sys.stderr)
        sys.exit(1)
    if not out:
        print(f"az command returned empty output: az {' '.join(args)}", file=sys.stderr)
        sys.exit(1)
    return out


def get_iothub_owner_conn() -> str:
    return _az([
        "iot", "hub", "connection-string", "show",
        "--hub-name", IOTHUB_NAME,
        "--policy-name", "iothubowner",
        "--query", "connectionString", "-o", "tsv",
    ])


def get_appinsights_conn() -> str:
    return _az([
        "monitor", "app-insights", "component", "show",
        "-g", RESOURCE_GROUP,
        "--app", APPINSIGHTS_NAME,
        "--query", "connectionString", "-o", "tsv",
    ])


def load_devices(config_path: Path) -> list[dict]:
    if not config_path.exists():
        print(f"missing {config_path}", file=sys.stderr)
        sys.exit(1)
    try:
        devices = json.loads(config_path.read_text())
    except json.JSONDecodeError as e:
        print(f"{config_path} is not valid JSON: {e}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(devices, list) or not devices:
        print(f"{config_path} must be a non-empty JSON array", file=sys.stderr)
        sys.exit(1)
    required_keys = {"id", "telemetry_period_s", "crash_period_s"}
    for i, d in enumerate(devices):
        missing = required_keys - d.keys()
        if missing:
            print(f"{config_path}[{i}] missing keys: {sorted(missing)}", file=sys.stderr)
            sys.exit(1)
    ids = [d["id"] for d in devices]
    if len(ids) != len(set(ids)):
        print(f"{config_path} contains duplicate device ids: {ids}", file=sys.stderr)
        sys.exit(1)
    return devices


def ensure_device(registry: IoTHubRegistryManager, device_id: str) -> str:
    """Return the device's primary connection string, creating if absent."""
    try:
        device = registry.get_device(device_id)
        print(f"device '{device_id}' already exists")
    except Exception:
        print(f"creating device '{device_id}'")
        device = registry.create_device_with_sas(
            device_id=device_id,
            primary_key=None,
            secondary_key=None,
            status="enabled",
        )
    primary_key = device.authentication.symmetric_key.primary_key
    host = IOTHUB_NAME + ".azure-devices.net"
    return f"HostName={host};DeviceId={device_id};SharedAccessKey={primary_key}"


def write_env(device: dict, device_conn: str, ai_conn: str, env_path: Path) -> None:
    lines = [
        f"IOTHUB_DEVICE_CONNECTION_STRING={device_conn}",
        f"APPLICATIONINSIGHTS_CONNECTION_STRING={ai_conn}",
        f"DEVICE_ID={device['id']}",
        f"TELEMETRY_PERIOD_S={device['telemetry_period_s']}",
        f"CRASH_PERIOD_S={device['crash_period_s']}",
        "",
    ]
    env_path.write_text("\n".join(lines))
    print(f"wrote {env_path}")


def main() -> None:
    here = Path(__file__).parent
    devices = load_devices(here / DEVICES_CONFIG)
    print(f"bootstrapping simulator against {IOTHUB_NAME} ({len(devices)} device(s))")
    owner_conn = get_iothub_owner_conn()
    registry = IoTHubRegistryManager.from_connection_string(owner_conn)
    ai_conn = get_appinsights_conn()
    for device in devices:
        device_conn = ensure_device(registry, device["id"])
        write_env(device, device_conn, ai_conn, here / f".env.{device['id']}")
    print("bootstrap complete")


if __name__ == "__main__":
    main()
