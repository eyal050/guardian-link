"""One-time bootstrap: register device 'sim-01' in the IoT Hub and
persist its connection string (plus the App Insights connection
string) to .env.

Idempotent -- safe to re-run after terraform destroy/apply.
Uses `az` CLI subprocess for both connection-string reads so we
inherit the user's `az login` without needing separate IoT Hub
data-plane RBAC grants.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from azure.iot.hub import IoTHubRegistryManager


IOTHUB_NAME = "iot-guardianlink-dev-weu"
RESOURCE_GROUP = "rg-guardianlink-dev"
APPINSIGHTS_NAME = "appi-guardianlink-dev-weu"
DEVICE_ID = "sim-01"

DEFAULT_TELEMETRY_PERIOD_S = 20
DEFAULT_CRASH_PERIOD_S = 120


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


def write_env(device_conn: str, ai_conn: str, env_path: Path) -> None:
    lines = [
        f"IOTHUB_DEVICE_CONNECTION_STRING={device_conn}",
        f"APPLICATIONINSIGHTS_CONNECTION_STRING={ai_conn}",
        f"DEVICE_ID={DEVICE_ID}",
        f"TELEMETRY_PERIOD_S={DEFAULT_TELEMETRY_PERIOD_S}",
        f"CRASH_PERIOD_S={DEFAULT_CRASH_PERIOD_S}",
        "",
    ]
    env_path.write_text("\n".join(lines))
    print(f"wrote {env_path}")


def main() -> None:
    print(f"bootstrapping simulator against {IOTHUB_NAME}")
    owner_conn = get_iothub_owner_conn()
    registry = IoTHubRegistryManager.from_connection_string(owner_conn)
    device_conn = ensure_device(registry, DEVICE_ID)
    ai_conn = get_appinsights_conn()
    write_env(device_conn, ai_conn, Path(__file__).parent / ".env")
    print("bootstrap complete")


if __name__ == "__main__":
    main()
