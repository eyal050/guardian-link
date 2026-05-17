# Branching Strategy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the project over to a two-branch model where pushes to `dev` deploy to the dev Azure env and merges into `main` deploy to the prod Azure env, with the GH→ADO mirror and all ADO pipelines made branch-aware.

**Architecture:** GitHub remains the source of truth. The mirror workflow becomes branch-selective (pushes only the triggering branch to ADO). Every ADO pipeline gains `dev` to its trigger and uses compile-time `${{ if }}` blocks to emit only the env-appropriate stages. A new `guardianlink-infra-outputs-prod` variable group isolates prod outputs from dev.

**Tech Stack:** Azure DevOps YAML pipelines, GitHub Actions, ADO REST API, Terraform 1.9.8.

**Spec:** [`docs/superpowers/specs/2026-05-17-branching-strategy-design.md`](../specs/2026-05-17-branching-strategy-design.md)

**Commit strategy:** Per user preference, the spec stays uncommitted on disk until the implementation lands. All YAML changes + spec land in a single commit at Task 9, then pushed to a feature branch. Admin/validation tasks (10-14) are not commits.

**Pre-flight assumption:** Working from current branch `dev`. The first task creates a feature branch off it.

---

## File Structure

**Modified files (single commit at Task 9):**
- `.github/workflows/mirror-to-ado.yml` — selective per-branch push, dev+main triggers
- `pipelines/infra.yml` — branch-gated apply/destroy stages, new `post_apply_prod`
- `pipelines/templates/function-app.yml` — compile-time branch gating, real prod deploy
- `pipelines/telemetry-writer.yml` — add `dev` to trigger
- `pipelines/crash-classifier.yml` — add `dev` to trigger
- `pipelines/notifier.yml` — add `dev` to trigger
- `pipelines/metrics.yml` — add `dev` to trigger
- `pipelines/ml-stub.yml` — add `dev` to trigger, branch-gated deploy stages
- `pipelines/aks-consumer.yml` — add `dev` to trigger, add real prod deploy stage
- `pipelines/tests.yml` — convert from `pr:` trigger to branch `trigger:`
- `docs/superpowers/specs/2026-05-17-branching-strategy-design.md` — newly tracked

**Out-of-repo changes (admin tasks, no commit):**
- Create empty ADO variable group `guardianlink-infra-outputs-prod`
- GitHub branch protection rule on `main`
- Delete `public-prep` on `origin` and `ado`

---

### Task 1: Create feature branch and confirm baseline

**Files:** none — git operations only.

- [ ] **Step 1: Confirm clean working tree (except for the uncommitted spec)**

```bash
git status --short
```

Expected: only `?? docs/superpowers/specs/2026-05-17-branching-strategy-design.md` and any other pre-existing untracked items (`.claude/scheduled_tasks.lock`, `docs/superpowers/plans/2026-05-14-aks-consumer.md`, `docs/superpowers/plans/2026-05-15-tf-modularize-dev.md`). No modified tracked files.

- [ ] **Step 2: Create the feature branch from `dev`**

```bash
git checkout dev
git pull origin dev
git checkout -b feat/branching-strategy
```

- [ ] **Step 3: Verify ADO branches state for later cleanup**

```bash
git ls-remote ado | grep refs/heads
```

Note the output — should show `refs/heads/main` and `refs/heads/public-prep` (and possibly other branches). This is the baseline for Task 14 cleanup.

---

### Task 2: Rewrite `pipelines/infra.yml` for branch-gated stages

**Files:**
- Modify: `pipelines/infra.yml` (full rewrite)

**Why:** Today, `infra.yml` triggers only on `main` and runs dev→prod chained in one pipeline run. New model: triggers on both `dev` and `main`; emits only the matching env's stages.

- [ ] **Step 1: Replace `pipelines/infra.yml` with the new content**

```yaml
# pipelines/infra.yml
name: '$(Build.BuildId) - $(Date:yyyyMMdd) - $(Rev:r)'

parameters:
  - name: action
    displayName: 'Action'
    type: string
    default: apply
    values:
      - apply
      - destroy

trigger:
  branches:
    include:
      - dev
      - main
  paths:
    include:
      - terraform/environments/dev/**
      - terraform/environments/prod/**
      - pipelines/infra.yml
      - pipelines/templates/**

variables:
  - name: TERRAFORM_VERSION
    value: 1.9.8

stages:
  # === Apply, dev branch -> dev env ===
  - ${{ if and(eq(parameters.action, 'apply'), eq(variables['Build.SourceBranch'], 'refs/heads/dev')) }}:
    - template: templates/terraform-env.yml
      parameters:
        environment: dev
        tfDir: terraform/environments/dev
        variableGroup: guardianlink-dev
        adoEnvironment: dev
        stateKey: guardianlink-dev

    - stage: post_apply_dev
      displayName: Post-apply Dev
      dependsOn: apply_dev
      condition: succeeded()
      variables:
        - group: guardianlink-backend
        - group: guardianlink-dev
        - group: guardianlink-infra-outputs
      jobs:
        - job: publish_and_trigger
          displayName: Publish outputs + trigger app pipelines
          pool:
            vmImage: ubuntu-latest
          steps:
            - template: templates/steps/install-terraform.yml

            - task: AzureCLI@2
              displayName: Update guardianlink-infra-outputs variable group
              env:
                ADO_SETUP_PAT: $(ADO_SETUP_PAT)
                ADO_ORG: $(ADO_ORG)
                ADO_PROJECT_ID: $(ADO_PROJECT_ID)
              inputs:
                azureSubscription: guardianlink-azure
                scriptType: bash
                scriptLocation: inlineScript
                addSpnToEnvironment: true
                inlineScript: |
                  set -euo pipefail
                  cd terraform/environments/dev
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
                    -backend-config="key=guardianlink-dev" \
                    -input=false -reconfigure
                  TF_JSON=$(terraform output -json)
                  RG=$(echo "$TF_JSON"             | jq -r '.resource_group_name.value')
                  APPI=$(echo "$TF_JSON"           | jq -r '.app_insights_name.value')
                  ACR_SERVER=$(echo "$TF_JSON"     | jq -r '.acr_login_server.value')
                  ACR_NAME=$(echo "$TF_JSON"       | jq -r '.acr_name.value')
                  FUNC_TW=$(echo "$TF_JSON"        | jq -r '.func_telemetry_writer_name.value')
                  FUNC_CC=$(echo "$TF_JSON"        | jq -r '.func_crash_classifier_name.value')
                  FUNC_NOT=$(echo "$TF_JSON"       | jq -r '.func_notifier_name.value')
                  FUNC_MET=$(echo "$TF_JSON"       | jq -r '.func_metrics_name.value')
                  CA_ML=$(echo "$TF_JSON"          | jq -r '.container_app_ml_stub_name.value')
                  AKS_NAME=$(echo "$TF_JSON"              | jq -r '.aks_cluster_name.value')
                  CONSUMER_WI_CLIENT_ID=$(echo "$TF_JSON" | jq -r '.consumer_identity_client_id.value')
                  STORAGE_BLOB_URL=$(echo "$TF_JSON"      | jq -r '.storage_blob_url.value')
                  EH_FQDN=$(echo "$TF_JSON"              | jq -r '.eventhub_fqdn.value')
                  EH_NAME=$(echo "$TF_JSON"              | jq -r '.eventhub_name.value')
                  KV_NAME=$(echo "$TF_JSON"              | jq -r '.key_vault_name.value')

                  ADO_PROJECT="guardianlink"
                  VG_NAME="guardianlink-infra-outputs"
                  API="https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_apis/distributedtask"

                  VARIABLES=$(jq -n \
                    --arg rg "$RG" --arg appi "$APPI" \
                    --arg acr_s "$ACR_SERVER" --arg acr_n "$ACR_NAME" \
                    --arg tw "$FUNC_TW" --arg cc "$FUNC_CC" \
                    --arg not "$FUNC_NOT" --arg met "$FUNC_MET" \
                    --arg ca "$CA_ML" \
                    --arg aks_name "$AKS_NAME" \
                    --arg consumer_wi_client_id "$CONSUMER_WI_CLIENT_ID" \
                    --arg storage_blob_url "$STORAGE_BLOB_URL" \
                    --arg eh_fqdn "$EH_FQDN" \
                    --arg eh_name "$EH_NAME" \
                    --arg kv_name "$KV_NAME" \
                    '{
                      RESOURCE_GROUP_NAME:        {value: $rg},
                      APP_INSIGHTS_NAME:          {value: $appi},
                      ACR_LOGIN_SERVER:           {value: $acr_s},
                      ACR_NAME:                   {value: $acr_n},
                      FUNC_TELEMETRY_WRITER_NAME: {value: $tw},
                      FUNC_CRASH_CLASSIFIER_NAME: {value: $cc},
                      FUNC_NOTIFIER_NAME:         {value: $not},
                      FUNC_METRICS_NAME:          {value: $met},
                      CONTAINER_APP_ML_STUB_NAME: {value: $ca},
                      AKS_CLUSTER_NAME:             {value: $aks_name},
                      CONSUMER_IDENTITY_CLIENT_ID:  {value: $consumer_wi_client_id},
                      STORAGE_BLOB_URL:             {value: $storage_blob_url},
                      EVENT_HUB_FQDN:               {value: $eh_fqdn},
                      EVENT_HUB_NAME:               {value: $eh_name},
                      KV_NAME:                      {value: $kv_name}
                    }')

                  PROJECT_REF=$(jq -n \
                    --arg vgname "$VG_NAME" \
                    --arg proj_id "$ADO_PROJECT_ID" \
                    --arg proj_name "$ADO_PROJECT" \
                    '[{name: $vgname, projectReference: {id: $proj_id, name: $proj_name}}]')

                  VG_RESP=$(curl -sf -u ":${ADO_SETUP_PAT}" \
                    "${API}/variablegroups?groupName=${VG_NAME}&api-version=7.0")
                  VG_ID=$(echo "$VG_RESP" | jq -r '.value[0].id // empty')

                  if [ -n "$VG_ID" ]; then
                    PAYLOAD=$(jq -n \
                      --argjson id "$VG_ID" --arg name "$VG_NAME" \
                      --argjson vars "$VARIABLES" \
                      --argjson refs "$PROJECT_REF" \
                      '{id: $id, name: $name, type: "Vsts", variables: $vars, variableGroupProjectReferences: $refs}')
                    curl -sf -u ":${ADO_SETUP_PAT}" \
                      -X PUT -H "Content-Type: application/json" \
                      -d "$PAYLOAD" \
                      "${API}/variablegroups/${VG_ID}?api-version=7.0" > /dev/null
                    echo "Variable group ${VG_NAME} updated (id=${VG_ID})."
                  else
                    PAYLOAD=$(jq -n \
                      --arg name "$VG_NAME" \
                      --argjson vars "$VARIABLES" \
                      --argjson refs "$PROJECT_REF" \
                      '{name: $name, type: "Vsts", variables: $vars, variableGroupProjectReferences: $refs}')
                    curl -sf -u ":${ADO_SETUP_PAT}" \
                      -X POST -H "Content-Type: application/json" \
                      -d "$PAYLOAD" \
                      "${API}/variablegroups?api-version=7.0" > /dev/null
                    echo "Variable group ${VG_NAME} created."
                  fi

            - bash: |
                set -euo pipefail
                API="https://dev.azure.com/${ADO_ORG}/guardianlink/_apis/pipelines"
                PAYLOAD='{"resources":{"repositories":{"self":{"refName":"refs/heads/dev"}}}}'
                # Pipeline IDs: 7=telemetry-writer, 8=crash-classifier,
                #               9=notifier, 10=metrics, 11=ml-stub, 12=aks-consumer
                for pid in 7 8 9 10 11 12; do
                  BODY=$(curl -s -u ":${ADO_SETUP_PAT}" \
                    -X POST -H "Content-Type: application/json" \
                    -d "$PAYLOAD" \
                    -w "\nHTTP_STATUS:%{http_code}" \
                    "${API}/${pid}/runs?api-version=7.0")
                  STATUS=$(echo "$BODY" | grep "HTTP_STATUS:" | cut -d: -f2)
                  echo "Pipeline ${pid}: HTTP ${STATUS}"
                  if [ "$STATUS" != "200" ] && [ "$STATUS" != "201" ]; then
                    echo "--- Response body ---"
                    echo "$BODY" | grep -v "HTTP_STATUS:"
                    echo "---------------------"
                    exit 1
                  fi
                done
              displayName: Trigger app pipelines (dev)
              env:
                ADO_SETUP_PAT: $(ADO_SETUP_PAT)
                ADO_ORG: $(ADO_ORG)

  # === Apply, main branch -> prod env ===
  - ${{ if and(eq(parameters.action, 'apply'), eq(variables['Build.SourceBranch'], 'refs/heads/main')) }}:
    - template: templates/terraform-env.yml
      parameters:
        environment: prod
        tfDir: terraform/environments/prod
        variableGroup: guardianlink-prod
        adoEnvironment: prod
        stateKey: guardianlink-prod

    - stage: post_apply_prod
      displayName: Post-apply Prod
      dependsOn: apply_prod
      condition: succeeded()
      variables:
        - group: guardianlink-backend
        - group: guardianlink-prod
        - group: guardianlink-infra-outputs-prod
      jobs:
        - job: publish_and_trigger
          displayName: Publish prod outputs + trigger app pipelines
          pool:
            vmImage: ubuntu-latest
          steps:
            - template: templates/steps/install-terraform.yml

            - task: AzureCLI@2
              displayName: Update guardianlink-infra-outputs-prod variable group
              env:
                ADO_SETUP_PAT: $(ADO_SETUP_PAT)
                ADO_ORG: $(ADO_ORG)
                ADO_PROJECT_ID: $(ADO_PROJECT_ID)
              inputs:
                azureSubscription: guardianlink-azure
                scriptType: bash
                scriptLocation: inlineScript
                addSpnToEnvironment: true
                inlineScript: |
                  set -euo pipefail
                  cd terraform/environments/prod
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
                    -backend-config="key=guardianlink-prod" \
                    -input=false -reconfigure
                  TF_JSON=$(terraform output -json)
                  RG=$(echo "$TF_JSON"             | jq -r '.resource_group_name.value')
                  APPI=$(echo "$TF_JSON"           | jq -r '.app_insights_name.value')
                  ACR_SERVER=$(echo "$TF_JSON"     | jq -r '.acr_login_server.value')
                  ACR_NAME=$(echo "$TF_JSON"       | jq -r '.acr_name.value')
                  FUNC_TW=$(echo "$TF_JSON"        | jq -r '.func_telemetry_writer_name.value')
                  FUNC_CC=$(echo "$TF_JSON"        | jq -r '.func_crash_classifier_name.value')
                  FUNC_NOT=$(echo "$TF_JSON"       | jq -r '.func_notifier_name.value')
                  FUNC_MET=$(echo "$TF_JSON"       | jq -r '.func_metrics_name.value')
                  CA_ML=$(echo "$TF_JSON"          | jq -r '.container_app_ml_stub_name.value')
                  AKS_NAME=$(echo "$TF_JSON"              | jq -r '.aks_cluster_name.value')
                  CONSUMER_WI_CLIENT_ID=$(echo "$TF_JSON" | jq -r '.consumer_identity_client_id.value')
                  STORAGE_BLOB_URL=$(echo "$TF_JSON"      | jq -r '.storage_blob_url.value')
                  EH_FQDN=$(echo "$TF_JSON"              | jq -r '.eventhub_fqdn.value')
                  EH_NAME=$(echo "$TF_JSON"              | jq -r '.eventhub_name.value')
                  KV_NAME=$(echo "$TF_JSON"              | jq -r '.key_vault_name.value')

                  ADO_PROJECT="guardianlink"
                  VG_NAME="guardianlink-infra-outputs-prod"
                  API="https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_apis/distributedtask"

                  VARIABLES=$(jq -n \
                    --arg rg "$RG" --arg appi "$APPI" \
                    --arg acr_s "$ACR_SERVER" --arg acr_n "$ACR_NAME" \
                    --arg tw "$FUNC_TW" --arg cc "$FUNC_CC" \
                    --arg not "$FUNC_NOT" --arg met "$FUNC_MET" \
                    --arg ca "$CA_ML" \
                    --arg aks_name "$AKS_NAME" \
                    --arg consumer_wi_client_id "$CONSUMER_WI_CLIENT_ID" \
                    --arg storage_blob_url "$STORAGE_BLOB_URL" \
                    --arg eh_fqdn "$EH_FQDN" \
                    --arg eh_name "$EH_NAME" \
                    --arg kv_name "$KV_NAME" \
                    '{
                      RESOURCE_GROUP_NAME:        {value: $rg},
                      APP_INSIGHTS_NAME:          {value: $appi},
                      ACR_LOGIN_SERVER:           {value: $acr_s},
                      ACR_NAME:                   {value: $acr_n},
                      FUNC_TELEMETRY_WRITER_NAME: {value: $tw},
                      FUNC_CRASH_CLASSIFIER_NAME: {value: $cc},
                      FUNC_NOTIFIER_NAME:         {value: $not},
                      FUNC_METRICS_NAME:          {value: $met},
                      CONTAINER_APP_ML_STUB_NAME: {value: $ca},
                      AKS_CLUSTER_NAME:             {value: $aks_name},
                      CONSUMER_IDENTITY_CLIENT_ID:  {value: $consumer_wi_client_id},
                      STORAGE_BLOB_URL:             {value: $storage_blob_url},
                      EVENT_HUB_FQDN:               {value: $eh_fqdn},
                      EVENT_HUB_NAME:               {value: $eh_name},
                      KV_NAME:                      {value: $kv_name}
                    }')

                  PROJECT_REF=$(jq -n \
                    --arg vgname "$VG_NAME" \
                    --arg proj_id "$ADO_PROJECT_ID" \
                    --arg proj_name "$ADO_PROJECT" \
                    '[{name: $vgname, projectReference: {id: $proj_id, name: $proj_name}}]')

                  VG_RESP=$(curl -sf -u ":${ADO_SETUP_PAT}" \
                    "${API}/variablegroups?groupName=${VG_NAME}&api-version=7.0")
                  VG_ID=$(echo "$VG_RESP" | jq -r '.value[0].id // empty')

                  if [ -n "$VG_ID" ]; then
                    PAYLOAD=$(jq -n \
                      --argjson id "$VG_ID" --arg name "$VG_NAME" \
                      --argjson vars "$VARIABLES" \
                      --argjson refs "$PROJECT_REF" \
                      '{id: $id, name: $name, type: "Vsts", variables: $vars, variableGroupProjectReferences: $refs}')
                    curl -sf -u ":${ADO_SETUP_PAT}" \
                      -X PUT -H "Content-Type: application/json" \
                      -d "$PAYLOAD" \
                      "${API}/variablegroups/${VG_ID}?api-version=7.0" > /dev/null
                    echo "Variable group ${VG_NAME} updated (id=${VG_ID})."
                  else
                    PAYLOAD=$(jq -n \
                      --arg name "$VG_NAME" \
                      --argjson vars "$VARIABLES" \
                      --argjson refs "$PROJECT_REF" \
                      '{name: $name, type: "Vsts", variables: $vars, variableGroupProjectReferences: $refs}')
                    curl -sf -u ":${ADO_SETUP_PAT}" \
                      -X POST -H "Content-Type: application/json" \
                      -d "$PAYLOAD" \
                      "${API}/variablegroups?api-version=7.0" > /dev/null
                    echo "Variable group ${VG_NAME} created."
                  fi

            - bash: |
                set -euo pipefail
                API="https://dev.azure.com/${ADO_ORG}/guardianlink/_apis/pipelines"
                PAYLOAD='{"resources":{"repositories":{"self":{"refName":"refs/heads/main"}}}}'
                # Pipeline IDs: 7=telemetry-writer, 8=crash-classifier,
                #               9=notifier, 10=metrics, 11=ml-stub, 12=aks-consumer
                for pid in 7 8 9 10 11 12; do
                  BODY=$(curl -s -u ":${ADO_SETUP_PAT}" \
                    -X POST -H "Content-Type: application/json" \
                    -d "$PAYLOAD" \
                    -w "\nHTTP_STATUS:%{http_code}" \
                    "${API}/${pid}/runs?api-version=7.0")
                  STATUS=$(echo "$BODY" | grep "HTTP_STATUS:" | cut -d: -f2)
                  echo "Pipeline ${pid}: HTTP ${STATUS}"
                  if [ "$STATUS" != "200" ] && [ "$STATUS" != "201" ]; then
                    echo "--- Response body ---"
                    echo "$BODY" | grep -v "HTTP_STATUS:"
                    echo "---------------------"
                    exit 1
                  fi
                done
              displayName: Trigger app pipelines (main)
              env:
                ADO_SETUP_PAT: $(ADO_SETUP_PAT)
                ADO_ORG: $(ADO_ORG)

  # === Destroy, dev branch -> dev only ===
  - ${{ if and(eq(parameters.action, 'destroy'), eq(variables['Build.SourceBranch'], 'refs/heads/dev')) }}:
    - stage: destroy_dev
      displayName: Destroy Dev
      dependsOn: []
      variables:
        - group: guardianlink-backend
        - group: guardianlink-dev
        - group: guardianlink-infra-outputs
      jobs:
        - deployment: destroy
          displayName: terraform destroy
          environment: dev
          pool:
            vmImage: ubuntu-latest
          strategy:
            runOnce:
              deploy:
                steps:
                  - checkout: self

                  - template: templates/steps/install-terraform.yml

                  - task: AzureCLI@2
                    displayName: terraform destroy
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      addSpnToEnvironment: true
                      inlineScript: |
                        set -euo pipefail
                        cd terraform/environments/dev
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
                          -backend-config="key=guardianlink-dev" \
                          -input=false
                        terraform destroy -auto-approve -input=false
                    env:
                      TF_VAR_billing_scope_id: $(TF_VAR_billing_scope_id)
                      TF_VAR_alert_email: $(TF_VAR_alert_email)
                      TF_VAR_budget_contact_email: $(TF_VAR_budget_contact_email)
                      TF_VAR_owner: $(TF_VAR_owner)
                      TF_VAR_workload_subscription_id: $(TF_VAR_workload_subscription_id)

  # === Destroy, main branch -> prod only ===
  - ${{ if and(eq(parameters.action, 'destroy'), eq(variables['Build.SourceBranch'], 'refs/heads/main')) }}:
    - stage: destroy_prod
      displayName: Destroy Prod
      dependsOn: []
      variables:
        - group: guardianlink-backend
        - group: guardianlink-prod
      jobs:
        - deployment: destroy
          displayName: terraform destroy (prod)
          environment: prod
          pool:
            vmImage: ubuntu-latest
          strategy:
            runOnce:
              deploy:
                steps:
                  - checkout: self

                  - template: templates/steps/install-terraform.yml

                  - task: AzureCLI@2
                    displayName: terraform destroy
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      addSpnToEnvironment: true
                      inlineScript: |
                        set -euo pipefail
                        cd terraform/environments/prod
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
                          -backend-config="key=guardianlink-prod" \
                          -input=false
                        # Exclude azurerm_subscription.main from destroy — keeping the
                        # subscription disabled rather than deleted preserves state-key
                        # validity if prod is later re-deployed.
                        terraform state rm azurerm_subscription.main || true
                        terraform destroy -auto-approve -input=false
                    env:
                      TF_VAR_billing_scope_id: $(TF_VAR_billing_scope_id)
                      TF_VAR_alert_email: $(TF_VAR_alert_email)
                      TF_VAR_budget_contact_email: $(TF_VAR_budget_contact_email)
                      TF_VAR_owner: $(TF_VAR_owner)
                      TF_VAR_workload_subscription_id: $(TF_VAR_workload_subscription_id)
```

- [ ] **Step 2: Spot-check the edit**

Confirm the file contains four top-level `${{ if and(... }}:` blocks (apply-dev, apply-main, destroy-dev, destroy-main) and that each prod block writes to `guardianlink-infra-outputs-prod`.

```bash
grep -c "if and(eq(parameters.action" pipelines/infra.yml
```

Expected: `4`.

```bash
grep -c "guardianlink-infra-outputs-prod" pipelines/infra.yml
```

Expected: `1` (single VG_NAME assignment in the apply-main block).

---

### Task 3: Rewrite `pipelines/templates/function-app.yml` for compile-time branch gating

**Files:**
- Modify: `pipelines/templates/function-app.yml` (replace deploy stages)

**Why:** Today, `deploy_dev` is runtime-gated on `Build.SourceBranch == main` and `deploy_prod` is a stub. New model uses compile-time `${{ if }}` to emit only one of the two deploy stages, and `deploy_prod` becomes a real deploy reading from the prod outputs VG.

- [ ] **Step 1: Replace `pipelines/templates/function-app.yml` with the new content**

```yaml
# pipelines/templates/function-app.yml
parameters:
  - name: appDir
    type: string
  - name: pythonVersion
    type: string
    default: '3.10'
  - name: serviceConnection
    type: string
    default: guardianlink-azure

stages:
  - stage: build_test
    displayName: Build & Test
    jobs:
      - job: build_test
        displayName: Install and test
        pool:
          vmImage: ubuntu-latest
        steps:
          - task: UsePythonVersion@0
            displayName: Use Python ${{ parameters.pythonVersion }}
            inputs:
              versionSpec: ${{ parameters.pythonVersion }}

          - script: |
              cd ${{ parameters.appDir }}
              pip install -r requirements.txt -q
              pip install -r requirements-dev.txt -q
              pytest tests/ -v
            displayName: Install and run tests

  - ${{ if eq(variables['Build.SourceBranch'], 'refs/heads/dev') }}:
    - stage: deploy_dev
      displayName: Deploy to Dev
      dependsOn: build_test
      condition: succeeded()
      variables:
        - group: guardianlink-infra-outputs
      jobs:
        - deployment: deploy
          displayName: Deploy function app to dev
          environment: dev
          pool:
            vmImage: ubuntu-latest
          strategy:
            runOnce:
              deploy:
                steps:
                  - checkout: self

                  - script: |
                      SHORT_SHA="${BUILD_SOURCEVERSION:0:8}"
                      echo "##vso[task.setvariable variable=DEPLOY_VERSION]${BUILD_BUILDNUMBER}-${SHORT_SHA}"
                    displayName: Set deploy version string
                    env:
                      BUILD_SOURCEVERSION: $(Build.SourceVersion)
                      BUILD_BUILDNUMBER: $(Build.BuildNumber)

                  - task: UsePythonVersion@0
                    inputs:
                      versionSpec: ${{ parameters.pythonVersion }}

                  - script: |
                      cd ${{ parameters.appDir }}
                      pip install -r requirements.txt -q
                      zip -r "$(Build.ArtifactStagingDirectory)/function.zip" . \
                        -x "*.pyc" \
                        -x "*/__pycache__/*" \
                        -x "*__pycache__*" \
                        -x "tests/*" \
                        -x "*/tests/*" \
                        -x "requirements-dev.txt"
                    displayName: Package function app

                  - task: AzureCLI@2
                    displayName: Deploy zip package
                    inputs:
                      azureSubscription: ${{ parameters.serviceConnection }}
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        az functionapp deployment source config-zip \
                          --name "$(FUNCTION_APP_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --src "$(Build.ArtifactStagingDirectory)/function.zip"

                  - task: AzureCLI@2
                    displayName: Set DEPLOY_VERSION app setting
                    inputs:
                      azureSubscription: ${{ parameters.serviceConnection }}
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        az functionapp config appsettings set \
                          --name "$(FUNCTION_APP_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --settings "DEPLOY_VERSION=$(DEPLOY_VERSION)"

                  - task: AzureCLI@2
                    displayName: Tag resource with deploy version
                    inputs:
                      azureSubscription: ${{ parameters.serviceConnection }}
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        RESOURCE_ID=$(az functionapp show \
                          --name "$(FUNCTION_APP_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --query id -o tsv)
                        az tag update \
                          --resource-id "$RESOURCE_ID" \
                          --operation merge \
                          --tags "deploy-version=$(DEPLOY_VERSION)"

                  - task: AzureCLI@2
                    displayName: Create App Insights release annotation
                    inputs:
                      azureSubscription: ${{ parameters.serviceConnection }}
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        APP_RES_ID=$(az monitor app-insights component show \
                          --app "$(APP_INSIGHTS_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --query id -o tsv)
                        ANNO_ID=$(uuidgen)
                        ANNO_TIME=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
                        az rest \
                          --method post \
                          --uri "https://management.azure.com${APP_RES_ID}/Annotations?api-version=2015-05-01" \
                          --body "{\"Id\":\"${ANNO_ID}\",\"AnnotationName\":\"deploy-$(FUNCTION_APP_NAME)\",\"EventTime\":\"${ANNO_TIME}\",\"Category\":\"Deployment\",\"Properties\":\"{\\\"ReleaseVersion\\\":\\\"$(DEPLOY_VERSION)\\\"}\"}" \
                          || echo "Annotation skipped (workspace-based App Insights does not support this API)."

  - ${{ if eq(variables['Build.SourceBranch'], 'refs/heads/main') }}:
    - stage: deploy_prod
      displayName: Deploy to Prod
      dependsOn: build_test
      condition: succeeded()
      variables:
        - group: guardianlink-infra-outputs-prod
      jobs:
        - deployment: deploy
          displayName: Deploy function app to prod
          environment: prod
          pool:
            vmImage: ubuntu-latest
          strategy:
            runOnce:
              deploy:
                steps:
                  - checkout: self

                  - script: |
                      SHORT_SHA="${BUILD_SOURCEVERSION:0:8}"
                      echo "##vso[task.setvariable variable=DEPLOY_VERSION]${BUILD_BUILDNUMBER}-${SHORT_SHA}"
                    displayName: Set deploy version string
                    env:
                      BUILD_SOURCEVERSION: $(Build.SourceVersion)
                      BUILD_BUILDNUMBER: $(Build.BuildNumber)

                  - task: UsePythonVersion@0
                    inputs:
                      versionSpec: ${{ parameters.pythonVersion }}

                  - script: |
                      cd ${{ parameters.appDir }}
                      pip install -r requirements.txt -q
                      zip -r "$(Build.ArtifactStagingDirectory)/function.zip" . \
                        -x "*.pyc" \
                        -x "*/__pycache__/*" \
                        -x "*__pycache__*" \
                        -x "tests/*" \
                        -x "*/tests/*" \
                        -x "requirements-dev.txt"
                    displayName: Package function app

                  - task: AzureCLI@2
                    displayName: Deploy zip package
                    inputs:
                      azureSubscription: ${{ parameters.serviceConnection }}
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        az functionapp deployment source config-zip \
                          --name "$(FUNCTION_APP_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --src "$(Build.ArtifactStagingDirectory)/function.zip"

                  - task: AzureCLI@2
                    displayName: Set DEPLOY_VERSION app setting
                    inputs:
                      azureSubscription: ${{ parameters.serviceConnection }}
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        az functionapp config appsettings set \
                          --name "$(FUNCTION_APP_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --settings "DEPLOY_VERSION=$(DEPLOY_VERSION)"

                  - task: AzureCLI@2
                    displayName: Tag resource with deploy version
                    inputs:
                      azureSubscription: ${{ parameters.serviceConnection }}
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        RESOURCE_ID=$(az functionapp show \
                          --name "$(FUNCTION_APP_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --query id -o tsv)
                        az tag update \
                          --resource-id "$RESOURCE_ID" \
                          --operation merge \
                          --tags "deploy-version=$(DEPLOY_VERSION)"

                  - task: AzureCLI@2
                    displayName: Create App Insights release annotation
                    inputs:
                      azureSubscription: ${{ parameters.serviceConnection }}
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        APP_RES_ID=$(az monitor app-insights component show \
                          --app "$(APP_INSIGHTS_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --query id -o tsv)
                        ANNO_ID=$(uuidgen)
                        ANNO_TIME=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
                        az rest \
                          --method post \
                          --uri "https://management.azure.com${APP_RES_ID}/Annotations?api-version=2015-05-01" \
                          --body "{\"Id\":\"${ANNO_ID}\",\"AnnotationName\":\"deploy-$(FUNCTION_APP_NAME)\",\"EventTime\":\"${ANNO_TIME}\",\"Category\":\"Deployment\",\"Properties\":\"{\\\"ReleaseVersion\\\":\\\"$(DEPLOY_VERSION)\\\"}\"}" \
                          || echo "Annotation skipped (workspace-based App Insights does not support this API)."
```

- [ ] **Step 2: Spot-check**

```bash
grep -c "^  - \${{ if eq(variables\['Build.SourceBranch'\]" pipelines/templates/function-app.yml
```

Expected: `2` (one for dev, one for main).

```bash
grep -c "guardianlink-infra-outputs-prod" pipelines/templates/function-app.yml
```

Expected: `1`.

```bash
grep -c "eq(variables\['Build.SourceBranch'\], 'refs/heads/main')" pipelines/templates/function-app.yml
```

Expected: `1` — the old runtime condition on `deploy_dev` must be gone (it was `condition: and(succeeded(), eq(...))`). The only remaining occurrence is the compile-time `${{ if }}` guarding `deploy_prod`.

---

### Task 4: Branch-aware triggers + VG loading in all 4 function-app pipelines

**Files:**
- Modify: `pipelines/telemetry-writer.yml` (full rewrite)
- Modify: `pipelines/crash-classifier.yml` (full rewrite)
- Modify: `pipelines/notifier.yml` (full rewrite)
- Modify: `pipelines/metrics.yml` (full rewrite)

**Why:** Each of these pipelines extends the function-app template and currently triggers only on `main`, and pulls `guardianlink-infra-outputs` (dev's VG) at the pipeline level to resolve `FUNCTION_APP_NAME = $(FUNC_*_NAME)`. Two problems with just adding `dev` to the trigger:
1. Pipeline never fires on dev pushes (need `dev` in `branches.include`).
2. **Critical:** if a main-branch run kept the hardcoded `guardianlink-infra-outputs` at pipeline-level, `FUNCTION_APP_NAME` would resolve to the *dev* function app name, and the prod deploy stage would push prod code to the dev function app.

Fix: make the pipeline-level VG branch-conditional via `${{ if }}` so `FUNCTION_APP_NAME` resolves from the right VG per branch.

- [ ] **Step 1: Replace `pipelines/telemetry-writer.yml` with the new content**

```yaml
# pipelines/telemetry-writer.yml
trigger:
  branches:
    include:
      - dev
      - main
  paths:
    include:
      - apps/telemetry-writer/**
      - pipelines/telemetry-writer.yml
      - pipelines/templates/function-app.yml

variables:
  - name: FUNCTION_APP_NAME
    value: $(FUNC_TELEMETRY_WRITER_NAME)
  - ${{ if eq(variables['Build.SourceBranch'], 'refs/heads/dev') }}:
    - group: guardianlink-infra-outputs
  - ${{ if eq(variables['Build.SourceBranch'], 'refs/heads/main') }}:
    - group: guardianlink-infra-outputs-prod

stages:
  - template: templates/function-app.yml
    parameters:
      appDir: apps/telemetry-writer
```

- [ ] **Step 2: Replace `pipelines/crash-classifier.yml` with the analogous content** — same structure, `FUNCTION_APP_NAME = $(FUNC_CRASH_CLASSIFIER_NAME)`, paths `apps/crash-classifier/**`, `pipelines/crash-classifier.yml`, `appDir: apps/crash-classifier`.

- [ ] **Step 3: Replace `pipelines/notifier.yml` with the analogous content** — `FUNCTION_APP_NAME = $(FUNC_NOTIFIER_NAME)`, paths `apps/notifier/**`, `pipelines/notifier.yml`, `appDir: apps/notifier`.

- [ ] **Step 4: Replace `pipelines/metrics.yml` with the analogous content** — `FUNCTION_APP_NAME = $(FUNC_METRICS_NAME)`, paths `apps/metrics/**`, `pipelines/metrics.yml`, `appDir: apps/metrics`.

- [ ] **Step 5: Verify**

```bash
for f in pipelines/telemetry-writer.yml pipelines/crash-classifier.yml pipelines/notifier.yml pipelines/metrics.yml; do
  echo "=== $f ==="
  echo "prod VG refs: $(grep -c "guardianlink-infra-outputs-prod" "$f") (expect 1)"
  grep -A 3 "^trigger:" "$f" | head -4
done
```

Each output should show `prod VG refs: 1` and both `- dev` / `- main` under `branches.include`.

---

### Task 5: Restructure `pipelines/ml-stub.yml` (trigger + branch-gated deploys)

**Files:**
- Modify: `pipelines/ml-stub.yml` (full rewrite below the unchanged sections)

**Why:** ml-stub doesn't use the function-app template; it has its own deploy logic. It needs `dev` added to triggers, compile-time branch gating on its deploy stages, and a real prod deploy stage (today it's a stub).

- [ ] **Step 1: Replace `pipelines/ml-stub.yml` with the new content**

```yaml
# pipelines/ml-stub.yml
trigger:
  branches:
    include:
      - dev
      - main
  paths:
    include:
      - apps/ml-stub/**
      - pipelines/ml-stub.yml

stages:
  - stage: build_test
    displayName: Build & Test
    jobs:
      - job: build_test
        pool:
          vmImage: ubuntu-latest
        steps:
          - task: UsePythonVersion@0
            inputs:
              versionSpec: '3.10'

          - script: |
              cd apps/ml-stub
              pip install pytest -q
              pytest tests/ -v
            displayName: Run tests

  - ${{ if eq(variables['Build.SourceBranch'], 'refs/heads/dev') }}:
    - stage: build_push_dev
      displayName: Build, Push & Deploy to Dev
      dependsOn: build_test
      condition: succeeded()
      variables:
        - group: guardianlink-infra-outputs
      jobs:
        - deployment: deploy
          displayName: Build image, push to ACR, update Container App
          environment: dev
          pool:
            vmImage: ubuntu-latest
          strategy:
            runOnce:
              deploy:
                steps:
                  - checkout: self

                  - script: |
                      SHORT_SHA="${BUILD_SOURCEVERSION:0:8}"
                      echo "##vso[task.setvariable variable=DEPLOY_VERSION]${BUILD_BUILDNUMBER}-${SHORT_SHA}"
                    displayName: Set deploy version string
                    env:
                      BUILD_SOURCEVERSION: $(Build.SourceVersion)
                      BUILD_BUILDNUMBER: $(Build.BuildNumber)

                  - task: AzureCLI@2
                    displayName: Build and push image to ACR
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        az acr build \
                          --registry "$(ACR_NAME)" \
                          --image "ml-stub:$(DEPLOY_VERSION)" \
                          --image "ml-stub:latest" \
                          apps/ml-stub/

                  - task: AzureCLI@2
                    displayName: Update Container App image
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        az containerapp update \
                          --name "$(CONTAINER_APP_ML_STUB_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --container-name ml-stub \
                          --image "$(ACR_LOGIN_SERVER)/ml-stub:$(DEPLOY_VERSION)"

                  - task: AzureCLI@2
                    displayName: Tag Container App resource
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        RESOURCE_ID=$(az containerapp show \
                          --name "$(CONTAINER_APP_ML_STUB_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --query id -o tsv)
                        az tag update \
                          --resource-id "$RESOURCE_ID" \
                          --operation merge \
                          --tags "deploy-version=$(DEPLOY_VERSION)"

                  - task: AzureCLI@2
                    displayName: Create App Insights release annotation
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        APP_RES_ID=$(az monitor app-insights component show \
                          --app "$(APP_INSIGHTS_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --query id -o tsv)
                        ANNO_ID=$(uuidgen)
                        ANNO_TIME=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
                        az rest \
                          --method post \
                          --uri "https://management.azure.com${APP_RES_ID}/Annotations?api-version=2015-05-01" \
                          --body "{\"Id\":\"${ANNO_ID}\",\"AnnotationName\":\"deploy-ml-stub\",\"EventTime\":\"${ANNO_TIME}\",\"Category\":\"Deployment\",\"Properties\":\"{\\\"ReleaseVersion\\\":\\\"$(DEPLOY_VERSION)\\\"}\"}" \
                          || echo "Annotation skipped (workspace-based App Insights does not support this API)."

  - ${{ if eq(variables['Build.SourceBranch'], 'refs/heads/main') }}:
    - stage: build_push_prod
      displayName: Build, Push & Deploy to Prod
      dependsOn: build_test
      condition: succeeded()
      variables:
        - group: guardianlink-infra-outputs-prod
      jobs:
        - deployment: deploy_prod
          displayName: Build image, push to ACR, update Container App (prod)
          environment: prod
          pool:
            vmImage: ubuntu-latest
          strategy:
            runOnce:
              deploy:
                steps:
                  - checkout: self

                  - script: |
                      SHORT_SHA="${BUILD_SOURCEVERSION:0:8}"
                      echo "##vso[task.setvariable variable=DEPLOY_VERSION]${BUILD_BUILDNUMBER}-${SHORT_SHA}"
                    displayName: Set deploy version string
                    env:
                      BUILD_SOURCEVERSION: $(Build.SourceVersion)
                      BUILD_BUILDNUMBER: $(Build.BuildNumber)

                  - task: AzureCLI@2
                    displayName: Build and push image to ACR
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        az acr build \
                          --registry "$(ACR_NAME)" \
                          --image "ml-stub:$(DEPLOY_VERSION)" \
                          --image "ml-stub:latest" \
                          apps/ml-stub/

                  - task: AzureCLI@2
                    displayName: Update Container App image
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        az containerapp update \
                          --name "$(CONTAINER_APP_ML_STUB_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --container-name ml-stub \
                          --image "$(ACR_LOGIN_SERVER)/ml-stub:$(DEPLOY_VERSION)"

                  - task: AzureCLI@2
                    displayName: Tag Container App resource
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        RESOURCE_ID=$(az containerapp show \
                          --name "$(CONTAINER_APP_ML_STUB_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --query id -o tsv)
                        az tag update \
                          --resource-id "$RESOURCE_ID" \
                          --operation merge \
                          --tags "deploy-version=$(DEPLOY_VERSION)"

                  - task: AzureCLI@2
                    displayName: Create App Insights release annotation
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        APP_RES_ID=$(az monitor app-insights component show \
                          --app "$(APP_INSIGHTS_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --query id -o tsv)
                        ANNO_ID=$(uuidgen)
                        ANNO_TIME=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
                        az rest \
                          --method post \
                          --uri "https://management.azure.com${APP_RES_ID}/Annotations?api-version=2015-05-01" \
                          --body "{\"Id\":\"${ANNO_ID}\",\"AnnotationName\":\"deploy-ml-stub\",\"EventTime\":\"${ANNO_TIME}\",\"Category\":\"Deployment\",\"Properties\":\"{\\\"ReleaseVersion\\\":\\\"$(DEPLOY_VERSION)\\\"}\"}" \
                          || echo "Annotation skipped (workspace-based App Insights does not support this API)."
```

**Notes on what changed vs. the original:**
- Removed the top-level `variables: - group: guardianlink-infra-outputs` — replaced with per-stage variable groups so prod uses `guardianlink-infra-outputs-prod`.
- Removed the old `deploy_prod` stub stage at the bottom.
- Replaced the runtime-gated `build_push_dev` (was conditional on `Build.SourceBranch == main`) with two compile-time-gated stages: `build_push_dev` (dev branch only) and `build_push_prod` (main branch only).
- `build_push_prod` is a copy of the dev stage with: `environment: prod`, `variables.group: guardianlink-infra-outputs-prod`, deployment job name `deploy_prod`.

- [ ] **Step 2: Spot-check**

```bash
grep -c "if eq(variables\['Build.SourceBranch'\]" pipelines/ml-stub.yml
```

Expected: `2`.

```bash
grep -c "Prod stub" pipelines/ml-stub.yml
```

Expected: `0` (the old stub is gone).

---

### Task 6: Restructure `pipelines/aks-consumer.yml` (trigger + add prod deploy stage)

**Files:**
- Modify: `pipelines/aks-consumer.yml` (full rewrite below)

**Why:** aks-consumer today only has a `deploy_dev` stage (gated on `Build.SourceBranch == main`) and no prod deploy. Add `dev` to trigger, branch-gate `deploy_dev`, add a parallel `deploy_prod`.

- [ ] **Step 1: Replace `pipelines/aks-consumer.yml` with the new content**

```yaml
# pipelines/aks-consumer.yml
name: '$(Build.BuildId) - $(Date:yyyyMMdd) - $(Rev:r)'

trigger:
  branches:
    include:
      - dev
      - main
  paths:
    include:
      - apps/consumer/**
      - k8s/consumer/**
      - pipelines/aks-consumer.yml

variables:
  - name: IMAGE_REPOSITORY
    value: consumer

stages:
  - stage: build_scan
    displayName: Build, Push & Scan
    jobs:
      - job: build_scan
        displayName: Docker build, push, and Trivy scan
        pool:
          vmImage: ubuntu-latest
        variables:
          - ${{ if eq(variables['Build.SourceBranch'], 'refs/heads/dev') }}:
            - group: guardianlink-infra-outputs
          - ${{ if eq(variables['Build.SourceBranch'], 'refs/heads/main') }}:
            - group: guardianlink-infra-outputs-prod
        steps:
          - script: |
              SHORT_SHA="${BUILD_SOURCEVERSION:0:8}"
              TAG="${BUILD_BUILDNUMBER}-${SHORT_SHA}"
              echo "##vso[task.setvariable variable=IMAGE_TAG;isOutput=true]${TAG}"
              echo "IMAGE_TAG=${TAG}"
            displayName: Set image tag
            name: set_tag
            env:
              BUILD_SOURCEVERSION: $(Build.SourceVersion)
              BUILD_BUILDNUMBER: $(Build.BuildNumber)

          - task: AzureCLI@2
            displayName: Build and push to ACR
            inputs:
              azureSubscription: guardianlink-azure
              scriptType: bash
              scriptLocation: inlineScript
              inlineScript: |
                set -euo pipefail
                TAG="$(set_tag.IMAGE_TAG)"
                az acr build \
                  --registry "$(ACR_NAME)" \
                  --image "$(IMAGE_REPOSITORY):${TAG}" \
                  --image "$(IMAGE_REPOSITORY):latest" \
                  apps/consumer/

          - task: AzureCLI@2
            displayName: Trivy scan (fail on CRITICAL)
            inputs:
              azureSubscription: guardianlink-azure
              scriptType: bash
              scriptLocation: inlineScript
              inlineScript: |
                set -euo pipefail
                TAG="$(set_tag.IMAGE_TAG)"
                curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
                  | sh -s -- -b /usr/local/bin v0.61.0
                az acr login --name "$(ACR_NAME)"
                trivy image \
                  --exit-code 1 \
                  --severity CRITICAL \
                  --ignore-unfixed \
                  "$(ACR_LOGIN_SERVER)/$(IMAGE_REPOSITORY):${TAG}"

  - ${{ if eq(variables['Build.SourceBranch'], 'refs/heads/dev') }}:
    - stage: deploy_dev
      displayName: Deploy to Dev AKS
      dependsOn: build_scan
      condition: succeeded()
      variables:
        - group: guardianlink-infra-outputs
        - group: guardianlink-dev
        - name: IMAGE_TAG
          value: $[ stageDependencies.build_scan.build_scan.outputs['set_tag.IMAGE_TAG'] ]
      jobs:
        - deployment: deploy
          displayName: kubectl apply consumer manifests
          environment: dev
          pool:
            vmImage: ubuntu-latest
          strategy:
            runOnce:
              deploy:
                steps:
                  - checkout: self

                  - task: AzureCLI@2
                    displayName: Get AKS credentials
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        az aks get-credentials \
                          --name "$(AKS_CLUSTER_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --overwrite-existing

                  - task: Bash@3
                    displayName: Install kubectl
                    inputs:
                      targetType: inline
                      script: |
                        curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
                        chmod +x kubectl
                        sudo mv kubectl /usr/local/bin/kubectl

                  - task: AzureCLI@2
                    displayName: Apply manifests with envsubst
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        set -euo pipefail
                        export ACR_LOGIN_SERVER="$(ACR_LOGIN_SERVER)"
                        export IMAGE_TAG="$(IMAGE_TAG)"
                        export CONSUMER_IDENTITY_CLIENT_ID="$(CONSUMER_IDENTITY_CLIENT_ID)"
                        export AZURE_TENANT_ID="$(AZURE_TENANT_ID)"
                        export KV_NAME="$(KV_NAME)"
                        export EVENT_HUB_FQDN="$(EVENT_HUB_FQDN)"
                        export EVENT_HUB_NAME="$(EVENT_HUB_NAME)"
                        export STORAGE_BLOB_URL="$(STORAGE_BLOB_URL)"

                        for f in \
                          k8s/consumer/namespace.yaml \
                          k8s/consumer/serviceaccount.yaml \
                          k8s/consumer/secretproviderclass.yaml \
                          k8s/consumer/deployment.yaml \
                          k8s/consumer/hpa.yaml \
                          k8s/consumer/networkpolicy.yaml; do
                          envsubst < "$f" | kubectl apply -f -
                        done

                  - task: Bash@3
                    displayName: Wait for rollout
                    inputs:
                      targetType: inline
                      script: |
                        kubectl rollout status deployment/consumer -n consumer --timeout=5m

  - ${{ if eq(variables['Build.SourceBranch'], 'refs/heads/main') }}:
    - stage: deploy_prod
      displayName: Deploy to Prod AKS
      dependsOn: build_scan
      condition: succeeded()
      variables:
        - group: guardianlink-infra-outputs-prod
        - group: guardianlink-prod
        - name: IMAGE_TAG
          value: $[ stageDependencies.build_scan.build_scan.outputs['set_tag.IMAGE_TAG'] ]
      jobs:
        - deployment: deploy_prod
          displayName: kubectl apply consumer manifests (prod)
          environment: prod
          pool:
            vmImage: ubuntu-latest
          strategy:
            runOnce:
              deploy:
                steps:
                  - checkout: self

                  - task: AzureCLI@2
                    displayName: Get AKS credentials
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        az aks get-credentials \
                          --name "$(AKS_CLUSTER_NAME)" \
                          --resource-group "$(RESOURCE_GROUP_NAME)" \
                          --overwrite-existing

                  - task: Bash@3
                    displayName: Install kubectl
                    inputs:
                      targetType: inline
                      script: |
                        curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
                        chmod +x kubectl
                        sudo mv kubectl /usr/local/bin/kubectl

                  - task: AzureCLI@2
                    displayName: Apply manifests with envsubst
                    inputs:
                      azureSubscription: guardianlink-azure
                      scriptType: bash
                      scriptLocation: inlineScript
                      inlineScript: |
                        set -euo pipefail
                        export ACR_LOGIN_SERVER="$(ACR_LOGIN_SERVER)"
                        export IMAGE_TAG="$(IMAGE_TAG)"
                        export CONSUMER_IDENTITY_CLIENT_ID="$(CONSUMER_IDENTITY_CLIENT_ID)"
                        export AZURE_TENANT_ID="$(AZURE_TENANT_ID)"
                        export KV_NAME="$(KV_NAME)"
                        export EVENT_HUB_FQDN="$(EVENT_HUB_FQDN)"
                        export EVENT_HUB_NAME="$(EVENT_HUB_NAME)"
                        export STORAGE_BLOB_URL="$(STORAGE_BLOB_URL)"

                        for f in \
                          k8s/consumer/namespace.yaml \
                          k8s/consumer/serviceaccount.yaml \
                          k8s/consumer/secretproviderclass.yaml \
                          k8s/consumer/deployment.yaml \
                          k8s/consumer/hpa.yaml \
                          k8s/consumer/networkpolicy.yaml; do
                          envsubst < "$f" | kubectl apply -f -
                        done

                  - task: Bash@3
                    displayName: Wait for rollout
                    inputs:
                      targetType: inline
                      script: |
                        kubectl rollout status deployment/consumer -n consumer --timeout=5m
```

**Notes on what changed:**
- `trigger.branches.include` adds `dev`.
- The `build_scan` job uses two `${{ if }}` blocks (compile-time branch gating) to load the right VG — `guardianlink-infra-outputs` on dev, `guardianlink-infra-outputs-prod` on main — so `ACR_NAME` / `ACR_LOGIN_SERVER` come from the right env. (Compile-time `${{ if }}` is the safest pattern; `iif()` returning a literal string into `- group:` is not reliably supported across ADO YAML.)
- Added compile-time-gated `deploy_dev` (dev branch only) and `deploy_prod` (main branch only). The old runtime condition (`eq(Build.SourceBranch, 'refs/heads/main')`) is gone — it was inverted anyway (would have deployed dev only from main).

- [ ] **Step 2: Spot-check**

```bash
grep -c "if eq(variables\['Build.SourceBranch'\]" pipelines/aks-consumer.yml
```

Expected: `2`.

```bash
grep -c "deploy_prod" pipelines/aks-consumer.yml
```

Expected: `3` (stage name, deployment name, displayName).

---

### Task 7: Convert `pipelines/tests.yml` from PR trigger to branch trigger

**Files:**
- Modify: `pipelines/tests.yml` — replace the `pr:` block with a `trigger:` block

**Why:** ADO `pr:` triggers only fire on ADO-side PRs. Since GitHub owns PRs here, this pipeline has been dead. Convert to a branch trigger so cross-cutting unit tests actually run on every push to `dev` and `main`.

- [ ] **Step 1: Edit `pipelines/tests.yml`**

Replace this block:

```yaml
trigger: none   # manual and PR-triggered only

pr:
  branches:
    include:
      - main
      - dev
  paths:
    include:
      - apps/**
      - tests/**
      - pyproject.toml
      - scripts/run-tests.sh
      - pipelines/tests.yml
```

With:

```yaml
trigger:
  branches:
    include:
      - dev
      - main
  paths:
    include:
      - apps/**
      - tests/**
      - pyproject.toml
      - scripts/run-tests.sh
      - pipelines/tests.yml

pr: none
```

Leave the `variables:` block and below unchanged.

- [ ] **Step 2: Verify**

```bash
grep -A 1 "^trigger:" pipelines/tests.yml | head
```

Expected first lines:
```
trigger:
  branches:
```

```bash
grep "^pr:" pipelines/tests.yml
```

Expected: `pr: none`.

---

### Task 8: Rewrite `.github/workflows/mirror-to-ado.yml` for selective per-branch push

**Files:**
- Modify: `.github/workflows/mirror-to-ado.yml` (full rewrite)

**Why:** Today the workflow triggers only on `main` pushes and runs `git push ado --all`, mirroring every local branch as a side effect. New model: trigger on `dev` and `main`, push only the branch that fired the event.

- [ ] **Step 1: Replace `.github/workflows/mirror-to-ado.yml` with the new content**

```yaml
# .github/workflows/mirror-to-ado.yml
name: Mirror to Azure DevOps

on:
  push:
    branches:
      - dev
      - main
  workflow_dispatch:
    inputs:
      branch:
        description: 'Branch to mirror (dev or main)'
        required: true
        default: 'dev'

jobs:
  mirror:
    name: Push ${{ github.ref_name }} to ADO
    runs-on: ubuntu-latest
    steps:
      - name: Checkout full history
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          ref: ${{ github.ref }}

      - name: Push branch + tags to ADO
        run: |
          BRANCH="${{ github.ref_name }}"
          git remote add ado "https://eyal050:${ADO_MIRROR_PAT}@dev.azure.com/eyal050/guardianlink/_git/guardian-link"
          # Fetch ADO refs so --force-with-lease has a baseline. Without this,
          # on a fresh runner the lease has no expected value and the push
          # either fails with "stale info" (if remote ref exists) or behaves
          # like --force (if it doesn't). Fetching first makes the lease
          # meaningful: push only if ADO is at the commit we last saw.
          git fetch ado --prune || true
          git push ado "HEAD:refs/heads/${BRANCH}" --force-with-lease
          git push ado --tags
        env:
          ADO_MIRROR_PAT: ${{ secrets.ADO_MIRROR_PAT }}
```

- [ ] **Step 2: Verify**

```bash
grep -c "git push ado --all" .github/workflows/mirror-to-ado.yml
```

Expected: `0` (the broad push is gone).

```bash
grep "force-with-lease" .github/workflows/mirror-to-ado.yml
```

Expected: one match.

---

### Task 9: Commit all changes (spec + impl) to feature branch and push

**Files:** all modified files from Tasks 2–8 plus the previously untracked spec.

- [ ] **Step 1: Stage the spec and all modified files**

```bash
git add docs/superpowers/specs/2026-05-17-branching-strategy-design.md
git add docs/superpowers/plans/2026-05-17-branching-strategy.md
git add .github/workflows/mirror-to-ado.yml
git add pipelines/infra.yml
git add pipelines/templates/function-app.yml
git add pipelines/telemetry-writer.yml
git add pipelines/crash-classifier.yml
git add pipelines/notifier.yml
git add pipelines/metrics.yml
git add pipelines/ml-stub.yml
git add pipelines/aks-consumer.yml
git add pipelines/tests.yml
```

- [ ] **Step 2: Confirm the staged set**

```bash
git status
```

Expected: 12 files staged (1 spec, 1 plan, 1 workflow, 9 pipeline yamls). No other modified files.

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(ci): branch-aware deploy — dev branch -> dev env, main -> prod

GH Actions mirror now selectively pushes only the branch that fired the
event (dev or main) instead of git push --all. ADO pipelines (infra.yml
and all app pipelines) gain compile-time branch gating so each branch
emits only its env's deploy stages. New variable group
guardianlink-infra-outputs-prod isolates prod outputs from dev.

Spec: docs/superpowers/specs/2026-05-17-branching-strategy-design.md
Plan: docs/superpowers/plans/2026-05-17-branching-strategy.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Push the feature branch to GitHub**

```bash
git push -u origin feat/branching-strategy
```

Expected: branch published, no errors. (This push does NOT trigger the mirror workflow — it filters to dev/main only.)

---

### Task 10: Create empty `guardianlink-infra-outputs-prod` variable group

**Files:** none — admin task using ADO REST API from the local shell.

**Why:** The new function-app.yml template references `guardianlink-infra-outputs-prod` in the prod stage. ADO loads variable groups at runtime; if the VG doesn't exist when a main-branch pipeline runs, the stage fails to start. Pre-creating it as empty lets pipelines load — the first prod infra apply will populate values.

- [ ] **Step 1: Confirm `ADO_SETUP_PAT` is available locally**

```bash
test -n "${ADO_SETUP_PAT:-}" && echo "PAT present" || echo "ADO_SETUP_PAT not set — export it before continuing"
```

If not set, export it: `export ADO_SETUP_PAT=<your PAT>`. The PAT needs scope "Variable Groups — Read, create, & manage" (same one used elsewhere; rotated 2026-04-29 per reference memory).

- [ ] **Step 2: Look up the ADO project ID** (needed by the VG payload)

```bash
curl -sf -u ":${ADO_SETUP_PAT}" \
  "https://dev.azure.com/eyal050/_apis/projects?api-version=7.0" \
  | jq -r '.value[] | select(.name == "guardianlink") | .id'
```

Save the output as `ADO_PROJECT_ID`:

```bash
export ADO_PROJECT_ID=$(curl -sf -u ":${ADO_SETUP_PAT}" \
  "https://dev.azure.com/eyal050/_apis/projects?api-version=7.0" \
  | jq -r '.value[] | select(.name == "guardianlink") | .id')
echo "$ADO_PROJECT_ID"
```

Expected: a UUID like `abc12345-6789-...`.

- [ ] **Step 3: Create the empty variable group**

```bash
curl -sf -u ":${ADO_SETUP_PAT}" \
  -X POST -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg name "guardianlink-infra-outputs-prod" \
    --arg proj_id "$ADO_PROJECT_ID" \
    --arg proj_name "guardianlink" \
    '{
      name: $name,
      type: "Vsts",
      variables: {},
      variableGroupProjectReferences: [
        {name: $name, projectReference: {id: $proj_id, name: $proj_name}}
      ]
    }')" \
  "https://dev.azure.com/eyal050/guardianlink/_apis/distributedtask/variablegroups?api-version=7.0" \
  | jq '{id, name, type}'
```

Expected output:
```json
{
  "id": <some-int>,
  "name": "guardianlink-infra-outputs-prod",
  "type": "Vsts"
}
```

Note the `id` — record it alongside the other VG IDs in reference memory (currently 3 = backend, 4 = infra-outputs; this will be 5).

- [ ] **Step 4: Verify in the ADO UI**

Open `https://dev.azure.com/eyal050/guardianlink/_library?itemType=VariableGroups` in a browser and confirm `guardianlink-infra-outputs-prod` appears with no variables.

- [ ] **Step 5: Authorize pipelines to use the new VG**

Each pipeline that references the VG must be permitted (the standard ADO "Permit" step — see reference memory on resource authorization). The simplest UI path: open one of the app pipelines (e.g., pipeline ID 7, telemetry-writer), run it once from `main` after the merge (Task 12), and approve the permission prompt that appears for `guardianlink-infra-outputs-prod`. Repeat for each pipeline as needed, or pre-authorize via REST:

```bash
VG_ID=<id-from-step-3>
for pid in 6 7 8 9 10 11 12; do
  curl -sf -u ":${ADO_SETUP_PAT}" \
    -X PATCH -H "Content-Type: application/json" \
    -d "$(jq -n --argjson pid "$pid" \
      '{pipelines: [{id: $pid, authorized: true}]}')" \
    "https://dev.azure.com/eyal050/guardianlink/_apis/pipelines/pipelinepermissions/variablegroup/${VG_ID}?api-version=7.1-preview.1" \
    | jq '.allPipelines.authorized // false'
done
```

Expected: each call returns `false` (default for "all pipelines") but the per-pipeline authorization is recorded — visible by re-GETting the endpoint without `-X PATCH`.

---

### Task 11: PR `feat/branching-strategy` → `dev`, merge, validate dev path

**Files:** none — GitHub UI + observation.

**Why:** First end-to-end validation. The merge to `dev` triggers the new mirror workflow, which pushes only `dev` to ADO; ADO then fires `infra.yml` and the app pipelines on the dev branch, all with the new branch-gated stages.

- [ ] **Step 1: Open the PR**

```bash
gh pr create --base dev --head feat/branching-strategy \
  --title "ci: branch-aware deploy (dev -> dev env, main -> prod)" \
  --body "$(cat <<'EOF'
## Summary
- Mirror workflow now selectively pushes only the branch that fired the event
- ADO pipelines (infra + apps) gain compile-time branch gating so each branch emits only its env's stages
- Adds prod variable group reference: `guardianlink-infra-outputs-prod` (pre-created)
- Converts tests.yml from dead `pr:` trigger to branch trigger

See `docs/superpowers/specs/2026-05-17-branching-strategy-design.md` for full context.

## Test plan
- [ ] Merge to dev; verify GH Action mirrors `dev` to ADO `dev`
- [ ] Verify ADO `infra.yml` fires on ADO dev branch and applies dev env
- [ ] Verify each app pipeline triggers on dev push and deploys to dev env
- [ ] Confirm prod env is untouched throughout

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Record the PR URL output.

- [ ] **Step 2: Merge the PR** (linear / squash per your preference)

```bash
gh pr merge --merge <pr-number>
```

(Or via the GitHub UI. `main` doesn't have protection yet, so this PR-to-dev doesn't either; merge is a simple click.)

- [ ] **Step 3: Watch the mirror workflow**

```bash
gh run watch --workflow="Mirror to Azure DevOps"
```

Expected: workflow named `Push dev to ADO` runs and succeeds. The single push step should log a `HEAD:refs/heads/dev` push (not `--all`).

- [ ] **Step 4: Verify ADO received the dev branch update**

```bash
git fetch ado
git log ado/dev --oneline | head -5
```

Expected: top commit matches the merge commit on GitHub `dev`.

- [ ] **Step 5: Watch the ADO `infra` pipeline**

Open `https://dev.azure.com/eyal050/guardianlink/_build?definitionId=6` (infra is pipeline ID 6). A run should have started automatically from `refs/heads/dev`. Expected stage list:

- `validate_dev`, `plan_dev`, `apply_dev` (from `terraform-env.yml`)
- `post_apply_dev`

No `validate_prod` / `apply_prod` / `post_apply_prod` should appear. If they do, the `${{ if and(... }}` gating is wrong.

Approve the `dev` env gate when prompted. Apply should complete successfully.

- [ ] **Step 6: Watch the app pipelines**

Either triggered automatically by their own path trigger (if any `apps/**` or `pipelines/**` files changed in the merge) or by `post_apply_dev`'s REST call. Open each of pipeline IDs 7, 8, 9, 10, 11, 12 and confirm:

- `build_test` runs and passes
- `deploy_dev` (or `build_push_dev` for ml-stub) runs, NOT `deploy_prod`
- Function apps / containers / AKS rollouts in the dev env complete successfully

- [ ] **Step 7: Sanity-check prod is untouched**

```bash
az resource list --resource-group rg-guardianlink-prod -o table 2>&1 | head -5
```

Expected: either an empty list or only resources that pre-existed before this work (no fresh deploy timestamps on prod resources).

---

### Task 12: PR `dev` → `main`, merge, validate prod path

**Files:** none — GitHub UI + observation.

**Why:** Second end-to-end validation. The merge to `main` mirrors to ADO `main`, fires the prod side of every pipeline, and exercises the ADO `prod` environment approval gate.

- [ ] **Step 1: Open the PR**

```bash
gh pr create --base main --head dev \
  --title "ci: roll branching-strategy changes to main (prod cutover)" \
  --body "$(cat <<'EOF'
## Summary
- Rolls the dev-validated pipeline restructuring to main
- First prod cutover under the new model — exercises `guardianlink-infra-outputs-prod` and prod env approval

## Test plan
- [ ] Merge to main; verify GH Action mirrors `main` to ADO `main`
- [ ] ADO `infra.yml` runs only the `apply_prod` + `post_apply_prod` stages
- [ ] `post_apply_prod` populates `guardianlink-infra-outputs-prod` with real values
- [ ] App pipelines fire on `refs/heads/main` and run only `deploy_prod` stages
- [ ] ADO prod env approval is required and grants successfully
- [ ] Dev env is untouched throughout
🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Merge the PR**

```bash
gh pr merge --merge <pr-number>
```

- [ ] **Step 3: Watch the mirror workflow**

```bash
gh run watch --workflow="Mirror to Azure DevOps"
```

Expected: workflow named `Push main to ADO` runs and succeeds.

- [ ] **Step 4: Verify ADO `main` updated**

```bash
git fetch ado
git log ado/main --oneline | head -5
```

Expected: top commit matches the merge commit on GitHub `main`.

- [ ] **Step 5: Watch the ADO `infra` pipeline on `main`**

A run should have started from `refs/heads/main`. Expected stage list:

- `validate_prod`, `plan_prod`, `apply_prod` (from `terraform-env.yml`)
- `post_apply_prod`

NO `apply_dev` / `post_apply_dev` should appear. Approve the `prod` env gate when prompted. Apply runs — first apply on a fresh prod env may take 15–20 min.

- [ ] **Step 6: Verify `guardianlink-infra-outputs-prod` populated**

After `post_apply_prod` completes:

```bash
curl -sf -u ":${ADO_SETUP_PAT}" \
  "https://dev.azure.com/eyal050/guardianlink/_apis/distributedtask/variablegroups?groupName=guardianlink-infra-outputs-prod&api-version=7.0" \
  | jq '.value[0].variables | keys'
```

Expected: keys including `RESOURCE_GROUP_NAME`, `APP_INSIGHTS_NAME`, `ACR_LOGIN_SERVER`, `ACR_NAME`, `FUNC_*`, `CONTAINER_APP_ML_STUB_NAME`, `AKS_CLUSTER_NAME`, etc.

- [ ] **Step 7: Watch app pipelines deploy to prod**

Each app pipeline (IDs 7-12) should run with only the `deploy_prod` (or `build_push_prod`) stage. May need to manually re-run if they started before infra completed (would have failed with empty VG values).

Approve the `prod` env gate for each. Verify the prod resources have fresh deploy timestamps:

```bash
az functionapp list --resource-group rg-guardianlink-prod --query "[].{name:name, lastModified:lastModifiedTimeUtc}" -o table
```

- [ ] **Step 8: Sanity-check dev is untouched**

```bash
az functionapp list --resource-group rg-guardianlink-dev --query "[].{name:name, lastModified:lastModifiedTimeUtc}" -o table
```

Expected: no fresh deploy timestamps on dev resources from this run.

---

### Task 13: Apply GitHub branch protection on `main`

**Files:** none — admin task via `gh` CLI or GitHub UI.

**Why:** Prevents direct pushes to `main`, enforcing the "merge = prod deploy trigger" invariant.

- [ ] **Step 1: Apply branch protection via `gh`**

```bash
gh api -X PUT "repos/eyal050/guardian-link/branches/main/protection" \
  --input - <<'EOF'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
```

Expected: HTTP 200 response with the protection config echoed back.

- [ ] **Step 2: Verify**

```bash
gh api "repos/eyal050/guardian-link/branches/main/protection" \
  | jq '{linear: .required_linear_history.enabled, pr: .required_pull_request_reviews.required_approving_review_count, force_push: .allow_force_pushes.enabled, deletion: .allow_deletions.enabled}'
```

Expected:
```json
{
  "linear": true,
  "pr": 1,
  "force_push": false,
  "deletion": false
}
```

- [ ] **Step 3: Try a direct push to main (should fail)**

```bash
git checkout main
git pull origin main
git commit --allow-empty -m "test: should be blocked"
git push origin main
```

Expected: push rejected with a "Required pull request reviews" or similar message. Discard the local empty commit afterward:

```bash
git reset --hard HEAD~1
```

- [ ] **Step 4: Add a short "branching" note to the README**

Open `README.md` and append (or insert into an existing "Development" / "Contributing" section) a brief block. Use the executor's judgment for placement — the exact wording is:

```markdown
## Branching & deployment

- **GitHub is the source of truth.** All code lives here; ADO is a one-way mirror used only for pipeline execution.
- `dev` branch: push (direct or via PR) deploys to the dev Azure environment.
- `main` branch: protected. Merge a PR (typically from `dev`) to deploy to the prod Azure environment. Requires manual approval at the ADO `prod` env gate.
- Do **not** push directly to ADO — the mirror will overwrite it on the next GitHub push.
```

Commit on a small docs branch and PR into `dev` → `main` (or do as a follow-up). Not blocking for the cutover.

---

### Task 14: Delete `public-prep` branch on both remotes

**Files:** none — git operations.

**Why:** `public-prep` is zero commits ahead of `main` (confirmed during planning). It's stale leftover from an earlier "go public" prep effort. Removing reduces what could mistakenly be mirrored or referenced.

- [ ] **Step 1: Confirm public-prep is still zero ahead of main**

```bash
git fetch origin
git log --oneline origin/public-prep ^origin/main 2>&1 | head
```

Expected: empty output (no commits ahead). If anything appears, stop and investigate before deleting.

- [ ] **Step 2: Delete on GitHub**

```bash
git push origin --delete public-prep
```

- [ ] **Step 3: Delete on ADO**

```bash
git push ado --delete public-prep
```

- [ ] **Step 4: Delete local tracking branch**

```bash
git branch -d public-prep
```

- [ ] **Step 5: Verify**

```bash
git branch -a
```

Expected: no `public-prep` entries (local or remote-tracking).

---

## Rollout Risks and Recovery

| If this happens... | Do this |
|---|---|
| Mirror workflow fails with "fetch first" on `--force-with-lease` | Someone pushed directly to ADO. `git fetch ado`, inspect `ado/<branch>` vs `origin/<branch>`, decide whether to merge ADO's commit into GH or overwrite. |
| App pipeline on main fails with "variable group not found" | `guardianlink-infra-outputs-prod` wasn't created (Task 10 was skipped). Run Task 10, then re-run the app pipeline. |
| App pipeline on main fails with empty variable values | Infra hadn't populated the VG when the app pipeline started. Wait for infra to complete, then re-run the app pipeline. |
| `infra.yml` runs on dev branch but emits prod stages (or vice versa) | The `${{ if and(... }}` gating evaluated wrong. Check `Build.SourceBranch` resolves to `refs/heads/dev` or `refs/heads/main` — branch policies and PR-build contexts can change this. |
| Branch protection blocks the cutover PR | Disable temporarily with `gh api -X DELETE repos/eyal050/guardian-link/branches/main/protection`, merge, then re-apply Task 13. |

---

## Acceptance Criteria

The branching strategy is fully cut over when:

- [ ] A push to `dev` mirrors only `dev` to ADO, fires `infra.yml` and app pipelines on the dev branch, deploys to dev env, prod env untouched.
- [ ] A merge to `main` mirrors only `main`, fires `infra.yml` and app pipelines on the main branch, requires ADO prod env approval, deploys to prod env, dev env untouched.
- [ ] Direct pushes to `main` on GitHub are rejected by branch protection.
- [ ] `public-prep` no longer exists on `origin` or `ado`.
- [ ] `guardianlink-infra-outputs-prod` variable group exists in ADO and is populated with prod resource names.
