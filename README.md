# GuardianLink — Azure IoT Safety Platform

> An interview-prep project: a realistic Azure cloud backend for a connected personal safety
> platform. Built end-to-end with Terraform, Azure DevOps, and full observability.

## What's been built

| Component | Tech |
|---|---|
| IoT Hub device ingestion | Azure IoT Hub |
| Telemetry streaming | Azure Event Hubs (4 partitions, RBAC-only auth) |
| Device simulators | Python async (`azure-iot-device`) |
| Event Hub inspector | Python async consumer |
| Telemetry writer | Azure Function (Python v2 model) |
| Crash classifier | Azure Function + configurable ML stub |
| Notifier (email/SMS) | Azure Function + SendGrid |
| Metrics aggregator | Azure Function |
| Device/event storage | Cosmos DB |
| Notification history | PostgreSQL Flexible Server |
| Message routing | Service Bus + Event Grid |
| Secrets management | Key Vault (managed identity throughout) |
| Observability | App Insights + Log Analytics Workspace + Workbook |
| Alerting | Azure Monitor scheduled-query rules (KQL) |
| CI/CD | Azure DevOps pipelines (OIDC — no stored credentials) |

All infrastructure is Terraform-managed. No Bicep, no ARM templates.

## Architecture

See [`docs/architecture.md`](docs/architecture.md) for the full design. Key decisions worth
asking about in an interview:

- **IoT Hub + Event Hubs, not just Event Hubs** — device identity, per-device quotas, and the
  D2C routing model matter for a connected safety device fleet.
- **Managed identity everywhere** — `local_authentication_enabled = false` on Event Hubs;
  every resource authenticates via Entra ID. No connection strings in app settings.
- **Separate Function Apps per workload** — the crash classifier and notifier have different
  SLOs and cannot share fate (see failure scenario #3).
- **ML stub** — the classifier is wired for a real model; the stub returns configurable
  confidence scores so the full pipeline can be exercised without one.

## Failure injection game

[`docs/failure-scenarios.md`](docs/failure-scenarios.md) catalogs realistic production failures.
Inject one (`"Break failure #N"` in Claude Code), diagnose it using only Azure Monitor and
App Insights, then post-mortem. This is the primary interview-prep exercise.

## Repo layout

```text
guardianlink/
├── README.md
├── CLAUDE.md                        # AI pair-programming instructions
├── LICENSE
├── docs/
│   ├── architecture.md
│   ├── terraform-structure.md
│   ├── failure-scenarios.md
│   └── job-description.md
├── terraform/
│   └── guardianlink-dev/            # single environment; one .tf file per resource type
│       ├── *.tf
│       ├── terraform.tfvars.example # copy to terraform.tfvars and fill in your values
│       └── run.sh
├── apps/
│   ├── simulator/                   # Python device simulator (runs as sim-01 / sim-02)
│   ├── consumer/                    # Python Event Hub inspector
│   ├── telemetry-writer/            # Azure Function
│   ├── crash-classifier/            # Azure Function + ML stub
│   ├── notifier/                    # Azure Function
│   └── metrics/                     # Azure Function
├── pipelines/
│   ├── infra.yml                    # Terraform plan → apply
│   ├── telemetry-writer.yml
│   ├── crash-classifier.yml
│   ├── notifier.yml
│   ├── metrics.yml
│   └── ml-stub.yml
├── alerts/                          # KQL files for Azure Monitor alert rules
└── dashboards/                      # Azure Monitor workbook JSON
```

---

## Setup guide (for candidates cloning this repo)

### Prerequisites

- **Azure account** with a Microsoft Customer Agreement (MCA) billing account
- **Azure CLI** installed and authenticated (`az login`)
- **Terraform** ≥ 1.7
- **Python** ≥ 3.10
- **Azure DevOps** organisation with:
  - A project
  - An Azure Resource Manager service connection using Workload Identity Federation (OIDC),
    named `guardianlink-azure`
  - A Variable Group named `guardianlink-backend` (populated in Step 2 below)

### Step 1 — Terraform variables

```bash
cp terraform/guardianlink-dev/terraform.tfvars.example terraform/guardianlink-dev/terraform.tfvars
# Edit terraform.tfvars — fill in billing_scope_id and subscription details
```

### Step 2 — Populate the ADO Variable Group

In ADO → Pipelines → Library, create a group named `guardianlink-backend` and add:

| Variable | Description | Secret? |
|---|---|---|
| `ARM_CLIENT_ID` | Federated app (service principal) client ID | Yes |
| `ARM_SUBSCRIPTION_ID` | Target workload subscription ID | Yes |
| `ARM_TENANT_ID` | Entra ID tenant ID | Yes |
| `TF_BACKEND_SUBSCRIPTION_ID` | Subscription holding TF remote state storage | Yes |
| `TF_BACKEND_RESOURCE_GROUP` | Resource group for TF state storage account | No |
| `TF_BACKEND_STORAGE_ACCOUNT` | Storage account name for TF state | No |
| `TF_BACKEND_CONTAINER` | Blob container for TF state | No |
| `TF_BACKEND_STATE_KEY` | Blob key, e.g. `guardianlink-dev.tfstate` | No |
| `TF_VAR_billing_scope_id` | MCA invoice-section scope path | Yes |
| `TF_VAR_alert_email` | Email address for Azure Monitor alerts | No |
| `TF_VAR_budget_contact_email` | Email address for budget threshold alerts | No |
| `TF_VAR_owner` | Value for the `owner` resource tag | No |
| `TF_VAR_workload_subscription_id` | Workload subscription ID | Yes |
| `ADO_SETUP_PAT` | PAT with Library write scope (used by the VG update step) | Yes |
| `ADO_ORG` | Your ADO organisation name | No |
| `ADO_PROJECT_ID` | Your ADO project GUID | No |

### Step 3 — Run the infra pipeline

Trigger `pipelines/infra.yml` in ADO. First run takes ~10 minutes and provisions all resources.

Alternatively, run locally:

```bash
cd terraform/guardianlink-dev

# Parent subscription (holds the TF state backend; NOT the workload sub)
export ARM_SUBSCRIPTION_ID="<parent-subscription-id>"

# TF state backend (pre-existing storage account in the parent sub)
export TF_BACKEND_RESOURCE_GROUP="<rg-name>"
export TF_BACKEND_STORAGE_ACCOUNT="<storage-account-name>"

# Workload variables
export TF_VAR_workload_subscription_id="<child-subscription-id>"
export TF_VAR_billing_scope_id="/providers/Microsoft.Billing/billingAccounts/..."
export TF_VAR_alert_email="<your-email>"
export TF_VAR_budget_contact_email="<your-email>"

./run.sh plan
./run.sh apply
```

### Step 4 — Run the device simulators

```bash
cd apps/simulator
pip install -r requirements.txt
python bootstrap.py          # provisions sim-01 and sim-02 device identities, writes .env files
python sim.py --env .env.sim-01 &
python sim.py --env .env.sim-02 &
```

### Step 5 — Run the Event Hub inspector

```bash
cd apps/consumer
pip install -r requirements.txt
python bootstrap.py          # grants your identity Event Hubs Data Receiver, writes .env
python consumer.py
```

### Step 6 — Verify end-to-end

- **App Insights** → Transaction search → filter by `message_received`: events from both simulators should appear
- **IoT Hub** → Metrics → Messages received: non-zero
- **Event Hubs** → Metrics → Incoming messages: non-zero
