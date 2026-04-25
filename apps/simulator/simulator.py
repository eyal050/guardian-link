"""Async device simulator: pushes telemetry + crash-suspect messages
until Ctrl-C. Instruments sends as log records in App Insights `traces`.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
from datetime import datetime, timezone
from pathlib import Path

from azure.iot.device import Message
from azure.iot.device.aio import IoTHubDeviceClient
from azure.monitor.opentelemetry import configure_azure_monitor
from dotenv import load_dotenv

from payload import build_crash_suspect, build_telemetry


log = logging.getLogger("simulator")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="GuardianLink device simulator (one process per device)")
    parser.add_argument(
        "--device",
        required=True,
        help="device id (must match an entry in devices.json); loads .env.<id>",
    )
    return parser.parse_args()


def _configure(device_id: str) -> dict:
    env_path = Path(__file__).parent / f".env.{device_id}"
    if not env_path.exists():
        raise SystemExit(
            f"missing {env_path}. add '{device_id}' to devices.json and run bootstrap.py."
        )
    load_dotenv(env_path)
    required = [
        "IOTHUB_DEVICE_CONNECTION_STRING",
        "APPLICATIONINSIGHTS_CONNECTION_STRING",
        "DEVICE_ID",
    ]
    missing = [k for k in required if not os.environ.get(k)]
    if missing:
        raise SystemExit(f"missing env vars in {env_path}: {missing}. re-run bootstrap.py.")
    if os.environ["DEVICE_ID"] != device_id:
        raise SystemExit(
            f"DEVICE_ID mismatch: --device={device_id} but {env_path} has "
            f"DEVICE_ID={os.environ['DEVICE_ID']}. re-run bootstrap.py."
        )
    # basicConfig MUST run before configure_azure_monitor: the OTel distro
    # attaches its own handler to the root logger, after which basicConfig
    # becomes a no-op and nothing reaches stderr.
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    configure_azure_monitor(
        connection_string=os.environ["APPLICATIONINSIGHTS_CONNECTION_STRING"],
    )
    return {
        "device_id": os.environ["DEVICE_ID"],
        "telemetry_period_s": float(os.environ.get("TELEMETRY_PERIOD_S", "20")),
        "crash_period_s": float(os.environ.get("CRASH_PERIOD_S", "120")),
        "conn_str": os.environ["IOTHUB_DEVICE_CONNECTION_STRING"],
    }


def _make_message(body: dict, event_type: str) -> Message:
    msg = Message(json.dumps(body))
    msg.content_encoding = "utf-8"
    msg.content_type = "application/json"
    msg.custom_properties["eventType"] = event_type
    return msg


async def _send_loop(
    client: IoTHubDeviceClient,
    device_id: str,
    period_s: float,
    event_type: str,
    builder,
) -> None:
    while True:
        try:
            body = builder(device_id, datetime.now(timezone.utc))
            await client.send_message(_make_message(body, event_type))
            log.info(
                "message_sent",
                extra={"event_type": event_type, "device_id": device_id},
            )
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001 - keep the loop alive on transient errors
            log.warning(
                "message_send_failed",
                extra={"event_type": event_type, "device_id": device_id, "error": repr(e)},
            )
        await asyncio.sleep(period_s)


async def _run(device_id: str) -> None:
    cfg = _configure(device_id)
    client = IoTHubDeviceClient.create_from_connection_string(cfg["conn_str"])

    await client.connect()
    log.info("connection_restored", extra={"device_id": cfg["device_id"]})

    telemetry_task = asyncio.create_task(
        _send_loop(client, cfg["device_id"], cfg["telemetry_period_s"], "telemetry", build_telemetry)
    )
    crash_task = asyncio.create_task(
        _send_loop(client, cfg["device_id"], cfg["crash_period_s"], "crash_suspect", build_crash_suspect)
    )

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_event.set)

    await stop_event.wait()
    log.info("shutting down")

    telemetry_task.cancel()
    crash_task.cancel()
    for t in (telemetry_task, crash_task):
        try:
            await t
        except asyncio.CancelledError:
            pass

    await client.shutdown()


def main() -> None:
    args = _parse_args()
    asyncio.run(_run(args.device))


if __name__ == "__main__":
    main()
