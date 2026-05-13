# GuardianLink — Setup Guide

## Prerequisites

- **Azure account** with a Microsoft Customer Agreement (MCA) billing account
- **Azure CLI** installed and authenticated (`az login`)
- **Terraform** ≥ 1.7
- **Python** ≥ 3.10
- **Azure DevOps** organisation with:
  - A project
  - An Azure Resource Manager service connection using Workload Identity Federation (OIDC), named `guardianlink-azure`
  - A Variable Group named `guardianlink-backend` (populated in Step 2 below)

---

## Step 1 — Terraform variables

```bash
cp terraform/guardianlink-dev/terraform.tfvars.example terraform/guardianlink-dev/terraform.tfvars
# Edit terraform.tfvars — fill in billing_scope_id and subscription details
```

---

## Step 2 — Populate the ADO Variable Group

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

---

## Step 3 — Run the infra pipeline

Trigger `pipelines/infra.yml` in ADO. First run takes ~10 minutes and provisions all resources.

**Alternatively, run locally:**

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

---

## Step 4 — Run the device simulators

```bash
cd apps/simulator
pip install -r requirements.txt
python bootstrap.py          # provisions sim-01 and sim-02 device identities, writes .env files
python sim.py --env .env.sim-01 &
python sim.py --env .env.sim-02 &
```

---

## Step 5 — Run the Event Hub inspector

```bash
cd apps/consumer
pip install -r requirements.txt
python bootstrap.py          # grants your identity Event Hubs Data Receiver, writes .env
python consumer.py
```

---

## Step 6 — Verify end-to-end

- **App Insights** → Transaction search → filter by `message_received`: events from both simulators should appear
- **IoT Hub** → Metrics → Messages received: non-zero
- **Event Hubs** → Metrics → Incoming messages: non-zero
