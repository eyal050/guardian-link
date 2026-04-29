# Public Repo Preparation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the GuardianLink repo safe for public GitHub visibility — clean git history, no sensitive identifiers, working CI/CD after secrets move to the ADO Variable Group, and a rewritten README serving interviewers and other candidates.

**Architecture:** Two `git filter-repo` passes rewrite history (replace sensitive strings; drop `tf-lab-boilerplate/`). Then live files are fixed to remove remaining account-specific data. Secrets move from committed files to the ADO Variable Group and are injected as `TF_VAR_*` env vars. README is rewritten from scratch; MIT LICENSE is added. Final step: force-push to main.

**Tech Stack:** git-filter-repo (pip), Terraform ≥ 1.7, Azure DevOps Variable Groups, bash

---

## Additional findings vs. spec

Two items discovered while reading files that weren't in the spec:

- `terraform/guardianlink-dev/variables.tf` line 51: `workload_subscription_id` has `default = "<WORKLOAD_SUBSCRIPTION_ID>"` — a real subscription ID. Added to the replace-text pass and cleared in Task 5.
- `pipelines/infra.yml` line 211: `ADO_ORG="eyal050"` — ADO organisation name hardcoded. Moved to VG in Task 8/9.

---

## Files changed

**Modified:**
- `.gitignore` — remove `!terraform/guardianlink-dev/terraform.tfvars` exception
- `terraform/guardianlink-dev/variables.tf` — clear email and subscription ID defaults
- `terraform/guardianlink-dev/alerts.tf` — remove email from header comment
- `alerts/README.md` — genericise email reference
- `pipelines/infra.yml` — move ADO_ORG/ADO_PROJECT_ID to VG; add TF_VAR_* env blocks to plan and apply tasks
- `README.md` — full rewrite

**Created:**
- `LICENSE` — MIT

**Deleted from history + working tree:**
- `tf-lab-boilerplate/` (all contents)

**Temporary (never committed):**
- `replacements.txt` — used by git filter-repo, then deleted

---

### Task 1: Preparation — save sensitive values and create branch

**Files:** none

- [ ] **Step 1: Record the real values that filter-repo will overwrite**

After the filter-repo replace-text pass, the working tree copy of `terraform.tfvars` will contain placeholders. Save the real values now (password manager or scratch pad outside the repo):

```bash
cat terraform/guardianlink-dev/terraform.tfvars
```

Values to save:
- `billing_scope_id` — the full MCA scope path
- Any other real values you want to keep for local runs

- [ ] **Step 2: Create and check out public-prep branch**

```bash
git checkout -b public-prep
```

Expected: `Switched to a new branch 'public-prep'`

- [ ] **Step 3: Confirm clean working tree**

```bash
git status
```

Expected: `nothing to commit, working tree clean` (gitignored files are fine)

---

### Task 2: git filter-repo — replace sensitive strings across all history

**Files:** `replacements.txt` (temp, deleted at end of task)

`git filter-repo` rewrites every commit's content. All SHAs change after this task. That is expected and intentional.

- [ ] **Step 1: Install git-filter-repo if not present**

```bash
pip install git-filter-repo 2>/dev/null || pip3 install git-filter-repo
git filter-repo --version
```

Expected: a version string, e.g. `git filter-repo version 2.45.0`

- [ ] **Step 2: Create replacements.txt**

Create `replacements.txt` at the repo root. Order matters — the full billing scope path must appear before its component sub-strings:

```
<BILLING_SCOPE_ID>==>BILLING_SCOPE_ID_PLACEHOLDER
<BILLING_ACCOUNT_NAME>==>BILLING_ACCOUNT_NAME_PLACEHOLDER
<BILLING_PROFILE_NAME>==>BILLING_PROFILE_NAME_PLACEHOLDER
<INVOICE_SECTION_NAME>==>INVOICE_SECTION_NAME_PLACEHOLDER
<ADO_PROJECT_ID>==>ADO_PROJECT_ID_PLACEHOLDER
<WORKLOAD_SUBSCRIPTION_ID>==>WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER
```

- [ ] **Step 3: Run the replace-text pass**

```bash
git filter-repo --replace-text replacements.txt --force
```

Expected: progress lines like `Parsed 60 commits`, no errors.

- [ ] **Step 4: Verify history is clean**

```bash
git log -p | grep -E "<BILLING_ID_PATTERNS>"
```

Expected: no output.

- [ ] **Step 5: Verify working tree has placeholders**

```bash
grep "BILLING_SCOPE_ID_PLACEHOLDER" terraform/guardianlink-dev/terraform.tfvars
```

Expected: one matching line.

- [ ] **Step 6: Restore real values to terraform.tfvars (do NOT commit)**

The filter-repo pass replaced the real value in the working tree. Edit `terraform/guardianlink-dev/terraform.tfvars` and put the real `billing_scope_id` back (the value you saved in Task 1 Step 1). Do not stage or commit this file — it will be untracked in Task 4.

- [ ] **Step 7: Delete replacements.txt**

```bash
rm replacements.txt
```

---

### Task 3: git filter-repo — remove tf-lab-boilerplate from all history

**Files:** none (folder removed from every commit)

- [ ] **Step 1: Run the path-removal pass**

```bash
git filter-repo --path tf-lab-boilerplate --invert-paths --force
```

Expected: progress output, no errors.

- [ ] **Step 2: Verify folder is gone from history**

```bash
git log --all --oneline -- tf-lab-boilerplate/
```

Expected: no output.

- [ ] **Step 3: Verify folder is gone from working tree**

```bash
ls tf-lab-boilerplate 2>&1
```

Expected: `ls: cannot access 'tf-lab-boilerplate': No such file or directory`

---

### Task 4: Fix .gitignore — stop tracking terraform.tfvars

**Files:** `.gitignore`

- [ ] **Step 1: Remove the tfvars exception line**

Open `.gitignore`. The Terraform section currently reads:

```
# Terraform
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
!terraform/guardianlink-dev/terraform.tfvars
.terraform.lock.hcl
crash.log
crash.*.log
```

Remove the `!terraform/guardianlink-dev/terraform.tfvars` line so it reads:

```
# Terraform
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
.terraform.lock.hcl
crash.log
crash.*.log
```

- [ ] **Step 2: Untrack the file from git's index**

```bash
git rm --cached terraform/guardianlink-dev/terraform.tfvars
```

Expected: `rm 'terraform/guardianlink-dev/terraform.tfvars'`

- [ ] **Step 3: Confirm the file is no longer tracked**

```bash
git ls-files terraform/guardianlink-dev/terraform.tfvars
```

Expected: no output.

- [ ] **Step 4: Confirm the file still exists locally**

```bash
ls terraform/guardianlink-dev/terraform.tfvars
```

Expected: the file path (it is now gitignored but present locally with real values).

- [ ] **Step 5: Commit**

```bash
git add .gitignore
git commit -m "chore: stop tracking terraform.tfvars; values move to ADO Variable Group"
```

---

### Task 5: Fix variables.tf — clear personal email and subscription ID defaults

**Files:** `terraform/guardianlink-dev/variables.tf`

- [ ] **Step 1: Update the three variables with personal defaults**

Change lines 37-53 from:

```hcl
variable "budget_contact_email" {
  type        = string
  default     = "eyal050@gmail.com"
  description = "Email that receives budget threshold alerts."
}

variable "owner" {
  type        = string
  default     = "eyal050@gmail.com"
  description = "Used in the owner tag."
}

variable "workload_subscription_id" {
  type        = string
  default     = "<WORKLOAD_SUBSCRIPTION_ID>"
  description = "Subscription ID of the existing workload subscription. Replaces azurerm_subscription.main for pipelines that lack billing alias permissions."
}
```

To:

```hcl
variable "budget_contact_email" {
  type        = string
  default     = ""
  description = "Email that receives budget threshold alerts."
}

variable "owner" {
  type        = string
  default     = ""
  description = "Used in the owner tag."
}

variable "workload_subscription_id" {
  type        = string
  default     = ""
  description = "Subscription ID of the existing workload subscription. Replaces azurerm_subscription.main for pipelines that lack billing alias permissions."
}
```

- [ ] **Step 2: Commit**

```bash
git add terraform/guardianlink-dev/variables.tf
git commit -m "chore: clear personal email and subscription ID defaults from variables.tf"
```

---

### Task 6: Fix alerts.tf — remove email from header comment

**Files:** `terraform/guardianlink-dev/alerts.tf`

- [ ] **Step 1: Replace lines 1-6**

Current:
```hcl
# Azure Monitor scheduled-query alerts on the producer side.
#
# Three rules, one action group with a single email receiver to
# eyal050@gmail.com. The KQL for each rule is sourced from
# alerts/queries/*.kql so the queries can be reviewed as standalone
# Kusto.
```

Replace with:
```hcl
# Azure Monitor scheduled-query alerts on the producer side.
#
# Three rules, one action group with a single email receiver (var.alert_email).
# The KQL for each rule is sourced from alerts/queries/*.kql so the queries
# can be reviewed as standalone Kusto.
```

- [ ] **Step 2: Commit**

```bash
git add terraform/guardianlink-dev/alerts.tf
git commit -m "chore: remove hardcoded email from alerts.tf header comment"
```

---

### Task 7: Fix alerts/README.md — genericise email reference

**Files:** `alerts/README.md`

- [ ] **Step 1: Replace the email in the prose**

Current lines 4-5:
```
deployed to `rg-guardianlink-dev`. Notifications go by email to
`eyal050@gmail.com`.
```

Replace with:
```
deployed to `rg-guardianlink-dev`. Notifications go by email to
the address in `var.alert_email` (set via the ADO Variable Group).
```

- [ ] **Step 2: Commit**

```bash
git add alerts/README.md
git commit -m "chore: genericise email reference in alerts/README.md"
```

---

### Task 8: Fix pipelines/infra.yml — inject TF_VAR_* and move hardcoded IDs to VG

**Files:** `pipelines/infra.yml`

Three sub-changes, all committed together.

- [ ] **Step 1: Add env block to the plan stage AzureCLI task**

Find the "Terraform init + plan" task (around line 89). It currently has no `env:` block. Add one between `addSpnToEnvironment: true` and `inlineScript:`:

```yaml
          - task: AzureCLI@2
            displayName: Terraform init + plan
            inputs:
              azureSubscription: guardianlink-azure
              scriptType: bash
              scriptLocation: inlineScript
              addSpnToEnvironment: true
            env:
              TF_VAR_billing_scope_id: $(TF_VAR_billing_scope_id)
              TF_VAR_alert_email: $(TF_VAR_alert_email)
              TF_VAR_budget_contact_email: $(TF_VAR_budget_contact_email)
              TF_VAR_owner: $(TF_VAR_owner)
              TF_VAR_workload_subscription_id: $(TF_VAR_workload_subscription_id)
            inlineScript: |
              cd terraform/guardianlink-dev
              export ARM_CLIENT_ID=$servicePrincipalId
              export ARM_TENANT_ID=$tenantId
              export ARM_SUBSCRIPTION_ID=$(TF_BACKEND_SUBSCRIPTION_ID)
              export ARM_USE_OIDC=true
              export ARM_OIDC_TOKEN=$idToken
              terraform init \
                -backend-config="subscription_id=$(TF_BACKEND_SUBSCRIPTION_ID)" \
                -backend-config="resource_group_name=$(TF_BACKEND_RESOURCE_GROUP)" \
                -backend-config="storage_account_name=$(TF_BACKEND_STORAGE_ACCOUNT)" \
                -backend-config="container_name=$(TF_BACKEND_CONTAINER)" \
                -backend-config="key=$(TF_BACKEND_STATE_KEY)" \
                -input=false
              terraform plan -out="$(Build.ArtifactStagingDirectory)/tfplan" -input=false
```

- [ ] **Step 2: Add env block to the apply stage AzureCLI task**

Find the "Terraform apply" task (around line 152). Add the same env block:

```yaml
                - task: AzureCLI@2
                  displayName: Terraform apply
                  inputs:
                    azureSubscription: guardianlink-azure
                    scriptType: bash
                    scriptLocation: inlineScript
                    addSpnToEnvironment: true
                  env:
                    TF_VAR_billing_scope_id: $(TF_VAR_billing_scope_id)
                    TF_VAR_alert_email: $(TF_VAR_alert_email)
                    TF_VAR_budget_contact_email: $(TF_VAR_budget_contact_email)
                    TF_VAR_owner: $(TF_VAR_owner)
                    TF_VAR_workload_subscription_id: $(TF_VAR_workload_subscription_id)
                  inlineScript: |
                    cd terraform/guardianlink-dev
                    export ARM_CLIENT_ID=$servicePrincipalId
                    export ARM_TENANT_ID=$tenantId
                    export ARM_SUBSCRIPTION_ID=$(TF_BACKEND_SUBSCRIPTION_ID)
                    export ARM_USE_OIDC=true
                    export ARM_OIDC_TOKEN=$idToken
                    terraform init \
                      -backend-config="subscription_id=$(TF_BACKEND_SUBSCRIPTION_ID)" \
                      -backend-config="resource_group_name=$(TF_BACKEND_RESOURCE_GROUP)" \
                      -backend-config="storage_account_name=$(TF_BACKEND_STORAGE_ACCOUNT)" \
                      -backend-config="container_name=$(TF_BACKEND_CONTAINER)" \
                      -backend-config="key=$(TF_BACKEND_STATE_KEY)" \
                      -input=false -reconfigure
                    terraform apply -input=false "$(Pipeline.Workspace)/tfplan-dev/tfplan"
```

- [ ] **Step 3: Move ADO_ORG and ADO_PROJECT_ID to VG in the update-VG step**

In the "Update guardianlink-infra-outputs variable group" task (around line 175), the existing `env:` block is:

```yaml
                  env:
                    ADO_SETUP_PAT: $(ADO_SETUP_PAT)
```

Expand it to:

```yaml
                  env:
                    ADO_SETUP_PAT: $(ADO_SETUP_PAT)
                    ADO_ORG: $(ADO_ORG)
                    ADO_PROJECT_ID: $(ADO_PROJECT_ID)
```

And inside the `inlineScript:`, replace the hardcoded lines (around line 211-213):

```bash
ADO_ORG="eyal050"
ADO_PROJECT="guardianlink"
ADO_PROJECT_ID="<ADO_PROJECT_ID>"
```

With:

```bash
ADO_ORG="${ADO_ORG}"
ADO_PROJECT="guardianlink"
ADO_PROJECT_ID="${ADO_PROJECT_ID}"
```

- [ ] **Step 4: Commit**

```bash
git add pipelines/infra.yml
git commit -m "chore: inject TF_VAR_* into plan/apply; move ADO org and project ID to VG"
```

---

### Task 9: Update ADO Variable Group (manual)

**Files:** none (Azure DevOps web UI)

These steps must be completed in the ADO UI before triggering the pipeline in Task 12.

- [ ] **Step 1: Open the Variable Group**

ADO → Pipelines → Library → `guardianlink-backend`

- [ ] **Step 2: Add the following variables**

| Variable | Value | Secret? |
|---|---|---|
| `TF_VAR_billing_scope_id` | Full MCA scope path (from your notes) | Yes |
| `TF_VAR_alert_email` | `eyal050@gmail.com` | No |
| `TF_VAR_budget_contact_email` | `eyal050@gmail.com` | No |
| `TF_VAR_owner` | `eyal050@gmail.com` | No |
| `TF_VAR_workload_subscription_id` | `<WORKLOAD_SUBSCRIPTION_ID>` | Yes |
| `ADO_ORG` | `eyal050` | No |
| `ADO_PROJECT_ID` | `<ADO_PROJECT_ID>` | No |

- [ ] **Step 3: Save the Variable Group**

---

### Task 10: Add MIT LICENSE

**Files:** `LICENSE` (create at repo root)

- [ ] **Step 1: Create LICENSE**

```
MIT License

Copyright (c) 2026 Eyal Levi

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Commit**

```bash
git add LICENSE
git commit -m "chore: add MIT license"
```

---

### Task 11: Rewrite README.md

**Files:** `README.md`

The current README says "Blueprint phase. Nothing built yet." — completely stale. Replace the entire file.

- [ ] **Step 1: Replace README.md with the following content**

```markdown
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
export TF_VAR_billing_scope_id="/providers/Microsoft.Billing/billingAccounts/..."
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
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README for public visibility (interviewer + candidate audiences)"
```

---

### Task 12: Verification and publish

- [ ] **Step 1: Verify no sensitive strings remain in history**

```bash
git log -p | grep -E "<BILLING_ID_PATTERNS>"
```

Expected: no output.

- [ ] **Step 2: Verify tf-lab-boilerplate is gone from all history**

```bash
git log --all --oneline -- tf-lab-boilerplate/
```

Expected: no output.

- [ ] **Step 3: Verify terraform.tfvars is not tracked**

```bash
git ls-files terraform/guardianlink-dev/terraform.tfvars
```

Expected: no output.

- [ ] **Step 4: Verify no hardcoded email defaults remain**

```bash
git ls-files | xargs grep "default.*eyal050@gmail.com"
```

Expected: no output.

- [ ] **Step 5: Verify no hardcoded account IDs remain in pipeline YAML**

```bash
grep -n "eyal050\b\|<ADO_PROJECT_ID>\|<WORKLOAD_SUBSCRIPTION_ID>" pipelines/infra.yml
```

Expected: no output.

- [ ] **Step 6: Push public-prep to remote and trigger the ADO infra pipeline**

```bash
git push origin public-prep --force
```

In ADO, manually trigger `pipelines/infra.yml` targeting the `public-prep` branch. Confirm the `plan_dev` stage passes — this proves TF_VAR_* injection is working.

- [ ] **Step 7: If pipeline passes — force-push to main**

```bash
git push origin public-prep:main --force
```

If the pipeline fails, diagnose before this step. Do not force-push a broken branch.
