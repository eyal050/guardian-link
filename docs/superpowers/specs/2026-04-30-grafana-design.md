# Grafana Design — GuardianLink Dev

**Date:** 2026-04-30  
**Status:** Approved, pending implementation  
**Scope:** Azure Managed Grafana (Standard SKU) + crash pipeline dashboard. Function health and e2e latency dashboards are deferred to future sessions.

---

## 1. Architecture & Components

Three new Azure resources and one new Terraform provider:

```
azurerm_dashboard_grafana  (amg-guardianlink-dev-weu, Standard SKU)
  └─ system-assigned managed identity
       └─ Monitoring Reader  →  rg-guardianlink-dev
            (reads Log Analytics + App Insights)

azurerm_role_assignment  →  data.azurerm_client_config.current  (Grafana Admin)
azurerm_role_assignment  →  var.grafana_viewer_principal_id      (Grafana Viewer)

grafana/grafana provider
  └─ grafana_data_source   (Azure Monitor — LAW + App Insights via managed identity)
  └─ grafana_dashboard     (crash pipeline — from dashboards/grafana/crash-pipeline.json)
```

**SKU:** Standard. Essential lacks team folders and advanced data source features not worth the €10/month saving for interview-prep value.

**Resource group:** `rg-guardianlink-dev` — no new RG.

**Naming:** `amg-guardianlink-dev-weu` (CAF prefix `amg`).

---

## 2. RBAC Model

| Principal | Role | How resolved |
|---|---|---|
| Terraform caller (local user or ADO SP) | Grafana Admin | `data.azurerm_client_config.current.object_id` — automatically correct in both contexts |
| On-call reader | Grafana Viewer | `var.grafana_viewer_principal_id` in `terraform.tfvars` |
| Grafana managed identity | Monitoring Reader on RG | `azurerm_dashboard_grafana.main.identity[0].principal_id` |

Using `data.azurerm_client_config.current` for Admin means no extra variable and no separate pipeline configuration: the ADO service principal gets Admin automatically (required so it can call the Grafana API during the `run.sh` bootstrap).

---

## 3. Terraform Layout

### New files

**`terraform/guardianlink-dev/grafana.tf`** — Azure-side resources:
- `azurerm_dashboard_grafana.main`
- `azurerm_role_assignment.grafana_admin`
- `azurerm_role_assignment.grafana_viewer`
- `azurerm_role_assignment.grafana_mon_reader`
- `output "grafana_endpoint"` (picked up by infra pipeline → VG 4)

**`terraform/guardianlink-dev/grafana-dashboards.tf`** — Grafana-provider resources:
- `grafana_data_source.azure_monitor`
- `grafana_dashboard.crash_pipeline` (reads `dashboards/grafana/crash-pipeline.json`)

### Changes to existing files

**`versions.tf`** — add `grafana/grafana` provider block pinned to `~> 3.0`. URL and auth read from `GRAFANA_URL` and `GRAFANA_AUTH` environment variables; no hardcoded values, no new tfvars keys.

**`variables.tf`** — add `var.grafana_viewer_principal_id` (AAD object ID of the on-call reader principal). Default `null` — if unset, the Viewer role assignment is skipped via `count = var.grafana_viewer_principal_id != null ? 1 : 0`.

**`terraform.tfvars.example`** — add `grafana_viewer_principal_id = "<aad-object-id>"` with a comment that it is optional.

### New file in repo root

**`dashboards/grafana/crash-pipeline.json`** — starts as `{}` (empty placeholder). Grafana accepts this without error. Replaced with real JSON after the dashboard is built in the UI and exported.

---

## 4. Bootstrap Sequence (`run.sh apply`)

The Grafana Terraform provider must be initialized with the Grafana endpoint URL, which only exists after the Azure resource is created. Both stages run in a single shell process inside one `AzureCLI@2` task — no stale OIDC tokens.

```bash
# Stage 1: create Azure resource + role assignments only
terraform apply \
  -target=azurerm_dashboard_grafana.main \
  -target=azurerm_role_assignment.grafana_admin \
  -target=azurerm_role_assignment.grafana_viewer \
  -target=azurerm_role_assignment.grafana_mon_reader

# Capture endpoint and Azure AD token for Grafana API
export GRAFANA_URL=$(terraform output -raw grafana_endpoint)
export GRAFANA_AUTH=$(az account get-access-token \
  --resource ce34e7e5-485f-4d76-964f-b3d2b16d1e4f \
  --query accessToken -o tsv)

# Stage 2: full apply — Grafana provider now has URL + auth
terraform apply
```

Azure Managed Grafana accepts Azure AD Bearer tokens at its HTTP API — `GRAFANA_AUTH` is not a Grafana API key but an AAD access token, which Azure proxies correctly. Token TTL is 1 hour, sufficient for any apply.

The ADO infra pipeline's existing "publish outputs" step picks up `grafana_endpoint` automatically and writes it to VG 4 (`guardianlink-infra-outputs`).

**ADO pipeline model:** The infra pipeline uses a plan-artifact workflow (plan in one stage, `terraform apply tfplan` in the next). It does NOT call `run.sh apply`. Instead, a dedicated **"Bootstrap Grafana provider resources"** task runs after the main apply, with its own fresh OIDC token. This task handles only the Grafana-provider resources (`grafana_data_source`, `grafana_dashboard`) that were excluded from the plan artifact. Each `AzureCLI@2` task gets its own valid token — the two-task split is safe and correct for this pipeline model.

---

## 5. Dashboard Workflow

### Crash pipeline dashboard (first)

**Panels:**
- `crash_suspect` events over time (timeseries)
- `crash_confirmed_published` vs `crash_below_threshold` side-by-side (stacked bar — makes failure #4 visible immediately: confirmed drops to zero while below-threshold spikes)
- Classifier confidence distribution (histogram)
- Notifier success/failure rate (stat panels)

**Data source:** Azure Monitor, querying the existing Log Analytics workspace via KQL (same queries used by App Insights Workbook, adapted for Grafana).

**Build workflow:**
1. Build dashboard interactively in Grafana UI
2. Export as JSON: Dashboard settings → JSON model
3. Save to `dashboards/grafana/crash-pipeline.json`
4. Commit alongside implementation code
5. Re-apply — `grafana_dashboard.crash_pipeline` now provisions it; dashboard survives env re-creation

### Deferred dashboards (future sessions)

2. **Function app health** — execution count, failure rate, p95 duration per function
3. **End-to-end latency** — IoT Hub ingestion to notification sent, correlating across App Insights traces

---

## 6. Cost Impact

| Resource | SKU | Estimated monthly cost |
|---|---|---|
| Azure Managed Grafana | Standard | verify on Azure pricing page — billed per active user hour; light single-user use is low, but confirm before leaving it running continuously |

**Action:** Add Grafana to the `terraform destroy` checklist when the environment is not in active use. Check current pricing on the Azure portal before the first apply — Standard SKU billing is usage-based and can be surprising if left idle-but-open.

---

## 7. Out of Scope

- Prometheus (no stable scrape targets in this serverless architecture)
- Grafana alerting rules (requires Standard SKU alerting config — separate slice)
- Grafana Teams / folder-level permissions (Standard feature, not needed for two-person RBAC)
