"""Idempotent bootstrap: grant the current az-logged-in user the
'Azure Event Hubs Data Receiver' role on the telemetry hub plus
'Storage Blob Data Contributor' on the checkpoint container, then
persist the App Insights connection string + hub + checkpoint
coordinates to .env.

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
STORAGE_ACCOUNT_PREFIX = "stgl"
CHECKPOINT_CONTAINER = "eh-checkpoints"

HUB_SCOPE = (
    f"/subscriptions/{SUBSCRIPTION_ID}"
    f"/resourceGroups/{RESOURCE_GROUP}"
    f"/providers/Microsoft.EventHub"
    f"/namespaces/{NAMESPACE}"
    f"/eventhubs/{EVENT_HUB}"
)


def _container_scope(storage_account: str) -> str:
    return (
        f"/subscriptions/{SUBSCRIPTION_ID}"
        f"/resourceGroups/{RESOURCE_GROUP}"
        f"/providers/Microsoft.Storage"
        f"/storageAccounts/{storage_account}"
        f"/blobServices/default"
        f"/containers/{CHECKPOINT_CONTAINER}"
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


def _grant_role(principal_oid: str, role: str, scope: str) -> None:
    result = _az(
        [
            "role", "assignment", "create",
            "--role", role,
            "--scope", scope,
            "--assignee-object-id", principal_oid,
            "--assignee-principal-type", "User",
        ],
        allow_nonzero=True,
    )
    if result.returncode == 0:
        print(f"granted '{role}' to {principal_oid}")
        return
    stderr = (result.stderr or "") + (result.stdout or "")
    if "RoleAssignmentExists" in stderr or "already exists" in stderr.lower():
        print(f"'{role}' already granted to {principal_oid}")
        return
    print(f"az role assignment create failed:\n{stderr}", file=sys.stderr)
    sys.exit(1)


def grant_data_receiver(principal_oid: str) -> None:
    _grant_role(principal_oid, "Azure Event Hubs Data Receiver", HUB_SCOPE)


def grant_blob_data_contributor(principal_oid: str, storage_account: str) -> None:
    _grant_role(
        principal_oid,
        "Storage Blob Data Contributor",
        _container_scope(storage_account),
    )


def get_storage_account_name() -> str:
    # The TF random_string suffix means the name isn't predictable, so
    # discover by prefix. Today there is one 'stgl*' account per stack;
    # if a second one is added, this selector will need a more specific
    # filter (e.g. by tag or by listing containers).
    out = _az([
        "storage", "account", "list",
        "-g", RESOURCE_GROUP,
        "--query", f"[?starts_with(name, '{STORAGE_ACCOUNT_PREFIX}')].name",
        "-o", "tsv",
    ]).stdout.strip()
    names = [n for n in out.splitlines() if n]
    if len(names) != 1:
        print(
            f"expected exactly one '{STORAGE_ACCOUNT_PREFIX}*' storage account "
            f"in {RESOURCE_GROUP}, found {names}",
            file=sys.stderr,
        )
        sys.exit(1)
    return names[0]


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


def write_env(ai_conn: str, storage_account: str, env_path: Path) -> None:
    blob_url = f"https://{storage_account}.blob.core.windows.net"
    lines = [
        f"EVENT_HUB_FQDN={NAMESPACE}.servicebus.windows.net",
        f"EVENT_HUB_NAME={EVENT_HUB}",
        f"CONSUMER_GROUP={CONSUMER_GROUP}",
        "STARTING_POSITION=@latest",
        f"APPLICATIONINSIGHTS_CONNECTION_STRING={ai_conn}",
        f"STORAGE_BLOB_ACCOUNT_URL={blob_url}",
        f"CHECKPOINT_CONTAINER={CHECKPOINT_CONTAINER}",
        "",
    ]
    env_path.write_text("\n".join(lines))
    print(f"wrote {env_path}")


def main() -> None:
    print(f"bootstrapping consumer for {NAMESPACE}/{EVENT_HUB} (cg={CONSUMER_GROUP})")
    oid = get_current_principal_oid()
    grant_data_receiver(oid)
    storage_account = get_storage_account_name()
    grant_blob_data_contributor(oid, storage_account)
    ai_conn = get_appinsights_conn()
    write_env(ai_conn, storage_account, Path(__file__).parent / ".env")
    print("bootstrap complete")
    print("note: RBAC propagation can take 30-60s on a fresh grant")


if __name__ == "__main__":
    main()
