# ADO Pipelines Design

**Date:** 2026-04-28
**Scope:** GitHub → ADO mirroring, WIF service connection, variable groups, per-component CI/CD pipelines

---

## 1. GitHub → ADO Git Mirroring

A GitHub Actions workflow at `.github/workflows/mirror-to-ado.yml` triggers on every push to `main`. It runs `git push --mirror` to the ADO git remote using an ADO PAT stored as a GitHub Actions secret `ADO_MIRROR_PAT`.

- ADO repo: created as an empty repo named `guardian-link` inside the `guardianlink` ADO project
- After the first mirror push, ADO pipelines use the ADO git copy as their source — GitHub is never touched by pipeline jobs
- Mirroring is one-directional: GitHub → ADO only

---

## 2. ADO One-Time Setup

### 2a. WIF Service Connection (automated via Azure CLI + ADO REST API)

Name: `guardianlink-azure`

Steps (automated by Claude Code once PAT is provided):
1. Create Azure AD app registration + service principal (`az ad app create`, `az ad sp create`)
2. Create federated credential on the SP pointing to ADO's OIDC issuer
3. Assign `Owner` on the target subscription to the SP (required because Terraform creates role assignments)
4. Create the ADO service connection via REST API, referencing the SP's `clientId` and `tenantId`

**Requires:** ADO PAT (Service Connections: Read & Write) + Azure CLI authenticated against the tenant.

### 2b. Variable Group: `guardianlink-backend` (automated via ADO REST API)

Stores Terraform backend config injected at `terraform init`:

| Variable | Description |
|---|---|
| `TF_BACKEND_RESOURCE_GROUP` | RG containing the state storage account |
| `TF_BACKEND_STORAGE_ACCOUNT` | Storage account name |
| `TF_BACKEND_CONTAINER` | Blob container name |
| `TF_BACKEND_STATE_KEY` | State file blob key (e.g. `guardianlink-dev.tfstate`) |

**Requires:** ADO PAT (Variable Groups: Read & Write) + backend config values from the user.

### 2c. Variable Group: `guardianlink-infra-outputs` (created and updated by infra pipeline)

Populated after every successful `apply_dev` by the infra pipeline via ADO REST API. App pipelines consume these at queue time.

| Variable | Terraform output |
|---|---|
| `APP_INSIGHTS_NAME` | `app_insights_name` |
| `ACR_LOGIN_SERVER` | `acr_login_server` |
| `FUNC_TELEMETRY_WRITER_NAME` | `func_telemetry_writer_name` |
| `FUNC_CRASH_CLASSIFIER_NAME` | `func_crash_classifier_name` |
| `FUNC_NOTIFIER_NAME` | `func_notifier_name` |
| `FUNC_METRICS_NAME` | `func_metrics_name` |
| `CONTAINER_APP_ML_STUB_NAME` | `container_app_ml_stub_name` |

**Constraint:** App pipelines must not run before at least one successful infra apply has populated this group.

### 2d. ADO Environments (manual, user creates in ADO UI)

Two environments under Pipelines → Environments:
- `dev` — no approval required (auto-deploys)
- `prod` — manual approval check required before any prod stage executes

---

## 3. Terraform: ACR Addition

A new `azurerm_container_registry` resource added to `terraform/guardianlink-dev/`, Basic SKU. The ml-stub Container App already exists in `ml-stub.tf` and will reference the new registry. A corresponding `acr_login_server` output is added to `outputs.tf` for the infra pipeline to write to `guardianlink-infra-outputs`.

---

## 4. Pipeline File Layout

```
pipelines/
├── templates/
│   └── function-app.yml       ← reusable template for all 4 Function Apps
├── infra.yml                  ← Terraform validate / plan / apply
├── telemetry-writer.yml       ← calls template
├── crash-classifier.yml       ← calls template
├── notifier.yml               ← calls template
├── metrics.yml                ← calls template
└── ml-stub.yml                ← Docker build / push / container app update

.github/
└── workflows/
    └── mirror-to-ado.yml      ← mirrors to ADO git on every push to main
```

Each pipeline file is registered as a separate ADO pipeline. Path-based triggers ensure a pipeline only fires when its relevant files change.

---

## 5. Version Tagging

**Format:** `$(Build.BuildNumber)-<shortSHA>`

ADO formats `Build.BuildNumber` as `YYYYMMDD.N` by default (N = nth run that day). `$(Build.SourceVersion)` is the full commit SHA; a Bash step extracts the first 8 characters: `SHORT_SHA="${BUILD_SOURCEVERSION:0:8}"`. The combined version string looks like `20260428.3-a1b2c3d4`.

Applied as:

| Target | Mechanism | Visible in portal |
|---|---|---|
| Function App | App setting `DEPLOY_VERSION` | Configuration → Application settings |
| Function App | Azure resource tag `deploy-version` | Tags blade |
| Function App | App Insights release annotation | Monitoring charts (vertical line) |
| Container App | Docker image tag `<acr>/ml-stub:<version>` | Revisions blade |
| Container App | Azure resource tag `deploy-version` | Tags blade |
| Container App | App Insights release annotation | Monitoring charts |

---

## 6. Individual Pipeline Shapes

### 6a. `infra.yml`

| Stage | Trigger | What it does |
|---|---|---|
| `validate` | auto | `terraform init -backend=false`, `fmt -check`, `validate` |
| `plan_dev` | auto, after validate | init with backend config from `guardianlink-backend`, `terraform plan -out=tfplan` |
| `apply_dev` | ADO env `dev` (auto) | `terraform apply tfplan`, then update `guardianlink-infra-outputs` variable group via ADO REST API |
| `plan_prod` | auto, after apply_dev | echo "prod workspace not yet configured" |
| `apply_prod` | ADO env `prod` (manual approval) | echo "prod workspace not yet configured" |

Path trigger: `terraform/guardianlink-dev/**` or `pipelines/infra.yml`.

### 6b. `templates/function-app.yml`

Parameters:

| Parameter | Type | Description |
|---|---|---|
| `appDir` | string | Path to function app, e.g. `apps/telemetry-writer` |
| `functionAppName` | string | Azure Function App resource name |
| `pythonVersion` | string | Default `3.10` |

Stages:

| Stage | What it does |
|---|---|
| `build_test` | `pip install -r requirements.txt`, `pip install -r requirements-dev.txt`, `pytest` |
| `deploy_dev` | ZIP deploy via `az functionapp deployment source config-zip`, set app setting `DEPLOY_VERSION`, set Azure resource tag `deploy-version`, create App Insights release annotation |
| `deploy_prod` | ADO env `prod` approval → echo "prod not yet configured" |

### 6c. Function App callers (`telemetry-writer.yml`, `crash-classifier.yml`, `notifier.yml`, `metrics.yml`)

Each caller is ~15 lines: sets `trigger.paths` (the app directory + its pipeline file) and calls `templates/function-app.yml` with `appDir`, `functionAppName`.

### 6d. `ml-stub.yml`

| Stage | What it does |
|---|---|
| `build_test` | `pip install`, `pytest` |
| `build_push_dev` | `docker build`, `docker push` to ACR with version tag, `az containerapp update --image`, set Azure resource tag `deploy-version`, create App Insights release annotation |
| `deploy_prod` | ADO env `prod` approval → echo "prod not yet configured" |

Path trigger: `apps/ml-stub/**` or `pipelines/ml-stub.yml`.

---

## 7. What the User Provides Before Implementation

| Item | Where used | Notes |
|---|---|---|
| ADO PAT (full control or scoped: Code RW + Variable Groups RW + Service Connections RW) | Mirror secret + service connection + variable group creation | Temporary; can be revoked after setup |
| Azure CLI session (`az login` in terminal) | SP creation + role assignment | Needed for WIF setup only |
| Backend config values (SA name, container, RG, state key) | `guardianlink-backend` variable group | From current deployment |
| ADO environments `dev` + `prod` created in UI | Pipeline approval gates | Manual step, 2 minutes in the portal |

---

## 8. Constraints and Dependencies

- App pipelines will error at deploy stages if `guardianlink-infra-outputs` has not been populated — they reference variables that will be empty (Function App name, ACR login server, etc.). The fix is to run the infra pipeline at least once before any app pipeline.
- The `guardianlink-backend` variable group must be linked to the ADO project pipeline library with "Allow access to all pipelines" or explicitly authorised per pipeline.
- The WIF service connection must be authorised for each pipeline the first time it runs (ADO prompts once per pipeline, not once globally).
- Prod stages are intentional stubs. When a prod workspace is built, the echo steps are replaced with real Terraform / deploy commands — the approval gate and stage wiring are already in place.
