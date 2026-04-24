"""Idempotent bootstrap: grant the current az-logged-in user the
'Azure Event Hubs Data Receiver' role on the telemetry hub, then
persist the App Insights connection string + hub coordinates to .env.

Shells out to `az` so we inherit the user's existing `az login`.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


SUBSCRIPTION_ID = "WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER"
RESOURCE_GROUP = "rg-guardianlink-dev"
NAMESPACE = "evhns-guardianlink-dev-weu"
EVENT_HUB = "telemetry"
CONSUMER_GROUP = "inspector"
APPINSIGHTS_NAME = "appi-guardianlink-dev-weu"

HUB_SCOPE = (
    f"/subscriptions/{SUBSCRIPTION_ID}"
    f"/resourceGroups/{RESOURCE_GROUP}"
    f"/providers/Microsoft.EventHub"
    f"/namespaces/{NAMESPACE}"
    f"/eventhubs/{EVENT_HUB}"
)


def _az(args: list[str], *, allow_nonzero: bool = False) -> subprocess.CompletedProcess:
    result = subprocess.run(["az", *args], capture_output=True, text=True)
    if result.returncode != 0 and not allow_nonzero:
        print(f"az command failed: az {' '.join(args)}", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        sys.exit(1)
    return result


def get_current_principal_oid() -> str:
    out = _az(["ad", "signed-in-user", "show", "--query", "id", "-o", "tsv"]).stdout.strip()
    if not out:
        print("could not resolve signed-in user object ID", file=sys.stderr)
        sys.exit(1)
    return out


def grant_data_receiver(principal_oid: str) -> None:
    result = _az(
        [
            "role", "assignment", "create",
            "--role", "Azure Event Hubs Data Receiver",
            "--scope", HUB_SCOPE,
            "--assignee-object-id", principal_oid,
            "--assignee-principal-type", "User",
        ],
        allow_nonzero=True,
    )
    if result.returncode == 0:
        print(f"granted 'Azure Event Hubs Data Receiver' to {principal_oid}")
        return
    stderr = (result.stderr or "") + (result.stdout or "")
    if "RoleAssignmentExists" in stderr or "already exists" in stderr.lower():
        print(f"role already granted to {principal_oid}")
        return
    print(f"az role assignment create failed:\n{stderr}", file=sys.stderr)
    sys.exit(1)


def get_appinsights_conn() -> str:
    out = _az([
        "monitor", "app-insights", "component", "show",
        "-g", RESOURCE_GROUP,
        "--app", APPINSIGHTS_NAME,
        "--query", "connectionString", "-o", "tsv",
    ]).stdout.strip()
    if not out:
        print("empty app insights connection string", file=sys.stderr)
        sys.exit(1)
    return out


def write_env(ai_conn: str, env_path: Path) -> None:
    lines = [
        f"EVENT_HUB_FQDN={NAMESPACE}.servicebus.windows.net",
        f"EVENT_HUB_NAME={EVENT_HUB}",
        f"CONSUMER_GROUP={CONSUMER_GROUP}",
        "STARTING_POSITION=@latest",
        f"APPLICATIONINSIGHTS_CONNECTION_STRING={ai_conn}",
        "",
    ]
    env_path.write_text("\n".join(lines))
    print(f"wrote {env_path}")


def main() -> None:
    print(f"bootstrapping consumer for {NAMESPACE}/{EVENT_HUB} (cg={CONSUMER_GROUP})")
    oid = get_current_principal_oid()
    grant_data_receiver(oid)
    ai_conn = get_appinsights_conn()
    write_env(ai_conn, Path(__file__).parent / ".env")
    print("bootstrap complete")
    print("note: RBAC propagation can take 30-60s on a fresh grant")


if __name__ == "__main__":
    main()
