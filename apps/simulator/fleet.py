"""In-cluster fleet runner.

Replaces the local "one terminal per device + bootstrap.py + .env files"
workflow for the AKS deployment. At startup it:

  1. reads the device roster from a mounted ConfigMap (JSON array),
  2. registers each device in IoT Hub via Workload Identity (control plane),
     reading back the per-device SAS key,
  3. runs every device concurrently in this one process until SIGTERM.

Device telemetry still flows over per-device SAS auth (that's how IoT Hub
device identities work); the Workload Identity is used only for the
control-plane registry operations, so no connection strings are ever
committed or hand-copied. Tinkering with the fleet (more devices, more
accidents) is done by editing the roster in the Helm values.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
from pathlib import Path

from azure.identity import DefaultAzureCredential
from azure.iot.device.aio import IoTHubDeviceClient
from azure.iot.hub import IoTHubRegistryManager
from azure.monitor.opentelemetry import configure_azure_monitor

from payload import build_crash_suspect, build_telemetry
from simulator import _send_loop  # reuse the per-device send loop


log = logging.getLogger("fleet")

DEFAULT_ROSTER_PATH = "/etc/guardianlink/devices.json"
REQUIRED_KEYS = {"id", "telemetry_period_s", "crash_period_s"}


def load_roster(path: Path) -> list[dict]:
    """Parse and validate the device roster. Mirrors bootstrap.py's checks."""
    if not path.exists():
        raise SystemExit(f"missing roster {path}")
    try:
        devices = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        raise SystemExit(f"{path} is not valid JSON: {e}")
    if not isinstance(devices, list) or not devices:
        raise SystemExit(f"{path} must be a non-empty JSON array")
    for i, d in enumerate(devices):
        missing = REQUIRED_KEYS - d.keys()
        if missing:
            raise SystemExit(f"{path}[{i}] missing keys: {sorted(missing)}")
    ids = [d["id"] for d in devices]
    if len(ids) != len(set(ids)):
        raise SystemExit(f"{path} contains duplicate device ids: {ids}")
    return devices


def register_devices(hostname: str, devices: list[dict]) -> dict[str, str]:
    """Register the roster via Workload Identity, return id -> connection string.

    Idempotent: existing devices are reused. The registry SDK is synchronous;
    this runs once at startup before the async send loops begin.
    """
    credential = DefaultAzureCredential()
    # from_token_credential prepends the https:// scheme itself; pass bare host.
    registry = IoTHubRegistryManager.from_token_credential(hostname, credential)
    conns: dict[str, str] = {}
    for d in devices:
        device_id = d["id"]
        try:
            device = registry.get_device(device_id)
            log.info("device_exists", extra={"device_id": device_id})
        except Exception:
            device = registry.create_device_with_sas(
                device_id=device_id, primary_key=None, secondary_key=None, status="enabled"
            )
            log.info("device_created", extra={"device_id": device_id})
        key = device.authentication.symmetric_key.primary_key
        conns[device_id] = f"HostName={hostname};DeviceId={device_id};SharedAccessKey={key}"
    return conns


async def _run_device(device: dict, conn_str: str) -> tuple[IoTHubDeviceClient, list]:
    client = IoTHubDeviceClient.create_from_connection_string(conn_str)
    await client.connect()
    log.info("device_connected", extra={"device_id": device["id"]})
    tasks = [
        asyncio.create_task(
            _send_loop(client, device["id"], float(device["telemetry_period_s"]), "telemetry", build_telemetry)
        ),
        asyncio.create_task(
            _send_loop(client, device["id"], float(device["crash_period_s"]), "crash_suspect", build_crash_suspect)
        ),
    ]
    return client, tasks


async def _run() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    configure_azure_monitor(connection_string=os.environ["APPLICATIONINSIGHTS_CONNECTION_STRING"])

    hostname = os.environ["IOTHUB_HOSTNAME"]
    roster = load_roster(Path(os.environ.get("ROSTER_PATH", DEFAULT_ROSTER_PATH)))
    log.info("fleet_starting", extra={"device_count": len(roster), "hostname": hostname})

    conns = register_devices(hostname, roster)

    clients: list[IoTHubDeviceClient] = []
    tasks: list[asyncio.Task] = []
    for device in roster:
        client, device_tasks = await _run_device(device, conns[device["id"]])
        clients.append(client)
        tasks.extend(device_tasks)

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_event.set)

    await stop_event.wait()
    log.info("fleet_shutting_down")

    for task in tasks:
        task.cancel()
    for task in tasks:
        try:
            await task
        except asyncio.CancelledError:
            pass
    for client in clients:
        await client.shutdown()


def main() -> None:
    asyncio.run(_run())


if __name__ == "__main__":
    main()
