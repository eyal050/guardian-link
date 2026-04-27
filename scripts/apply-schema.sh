#!/usr/bin/env bash
# Apply Postgres schema and create the notifier app-user.
# Run from the repo root after `terraform apply`.
# Requires: Python 3 with psycopg2-binary, az login active.
#   pip install psycopg2-binary
set -euo pipefail

KV="kv-guardianlink-dev-weu"
SUB="WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER"
PGHOST="psql-guardianlink-dev-weu.postgres.database.azure.com"

echo "Fetching credentials from Key Vault..."
PGADMIN_PASS=$(az keyvault secret show --vault-name "$KV" --name postgres-admin-password --subscription "$SUB" --query value -o tsv)
NOTIFIER_PASS=$(az keyvault secret show --vault-name "$KV" --name postgres-notifier-password --subscription "$SUB" --query value -o tsv)

python3 - "$PGHOST" "$PGADMIN_PASS" "$NOTIFIER_PASS" <<'PYEOF'
import sys, psycopg2

host, admin_pw, notifier_pw = sys.argv[1], sys.argv[2], sys.argv[3]
schema = open("apps/notifier/schema.sql").read()

conn = psycopg2.connect(host=host, dbname="guardianlink", user="psqladmin",
                        password=admin_pw, sslmode="require", connect_timeout=10)
conn.autocommit = True

with conn.cursor() as cur:
    print("Applying schema...")
    cur.execute(schema)

    print("Creating notifier role...")
    cur.execute("SELECT 1 FROM pg_roles WHERE rolname = 'notifier'")
    if cur.fetchone():
        cur.execute(f"ALTER ROLE notifier PASSWORD %s", (notifier_pw,))
    else:
        cur.execute(f"CREATE ROLE notifier LOGIN PASSWORD %s", (notifier_pw,))
    cur.execute("GRANT SELECT ON devices, emergency_contacts TO notifier")

conn.close()
print("Done. Tables and notifier role are ready.")
PYEOF
