# ADO Pipelines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire GitHub → ADO git mirroring, WIF service connection, variable groups, and per-component CI/CD pipelines for all deployable GuardianLink components.

**Architecture:** A GitHub Actions workflow mirrors every `main` push to an ADO git repo. ADO pipelines source from that mirror. A shared `function-app.yml` stages template handles build/test/deploy for all 4 Function Apps; `infra.yml` and `ml-stub.yml` are standalone. A WIF service connection (no client secret) authenticates pipeline jobs to Azure. Two variable groups carry config: `guardianlink-backend` (Terraform backend config) and `guardianlink-infra-outputs` (resource names written by the infra pipeline after each apply).

**Tech Stack:** Azure DevOps YAML pipelines, GitHub Actions, Azure CLI (`az functionapp`, `az containerapp`, `az acr`, `az monitor`), Terraform ≥ 1.6, Python 3.10.

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `terraform/guardianlink-dev/outputs.tf` | Modify | Add 7 outputs for pipeline consumption |
| `.github/workflows/mirror-to-ado.yml` | Create | Mirror every `main` push to ADO git |
| `pipelines/templates/function-app.yml` | Create | Reusable build/test/deploy stages for all 4 Functions |
| `pipelines/telemetry-writer.yml` | Create | Caller: telemetry-writer |
| `pipelines/crash-classifier.yml` | Create | Caller: crash-classifier |
| `pipelines/notifier.yml` | Create | Caller: notifier |
| `pipelines/metrics.yml` | Create | Caller: metrics |
| `pipelines/infra.yml` | Create | Terraform validate/plan/apply + infra-outputs update |
| `pipelines/ml-stub.yml` | Create | ACR build/push + Container App update |
| `scripts/setup-ado.sh` | Create | One-time: SP + federated cred + service connection + variable group |

**Note:** ACR is already defined in `terraform/guardianlink-dev/ml-stub.tf`. `acr_login_server` and `acr_name` outputs already exist there. Do not add another ACR resource.

---

## Task 1: Add Terraform outputs for pipeline consumption

**Files:** Modify `terraform/guardianlink-dev/outputs.tf`

- [ ] **Step 1: Append outputs to outputs.tf**

```hcl
output "app_insights_name" {
  value       = azurerm_application_insights.main.name
  description = "App Insights component name for release annotations."
}

output "resource_group_name" {
  value       = azurerm_resource_group.main.name
  description = "Workload resource group name for CLI commands."
}

output "func_telemetry_writer_name" {
  value       = azurerm_linux_function_app.telemetry_writer.name
  description = "Telemetry writer Function App name."
}

output "func_crash_classifier_name" {
  value       = azurerm_linux_function_app.crash_classifier.name
  description = "Crash classifier Function App name."
}

output "func_notifier_name" {
  value       = azurerm_linux_function_app.notifier.name
  description = "Notifier Function App name."
}

output "func_metrics_name" {
  value       = azurerm_linux_function_app.metrics.name
  description = "Metrics Function App name."
}

output "container_app_ml_stub_name" {
  value       = azurerm_container_app.ml_stub.name
  description = "ML stub Container App name."
}
```

- [ ] **Step 2: Validate**

```bash
cd terraform/guardianlink-dev
terraform fmt outputs.tf
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add terraform/guardianlink-dev/outputs.tf
git commit -m "feat(infra): add pipeline-consumption outputs to terraform"
```

---

## Task 2: Create GitHub mirror workflow

**Files:** Create `.github/workflows/mirror-to-ado.yml`

- [ ] **Step 1: Create the workflow directory and file**

```bash
mkdir -p .github/workflows
```

```yaml
# .github/workflows/mirror-to-ado.yml
name: Mirror to Azure DevOps

on:
  push:
    branches:
      - main

jobs:
  mirror:
    name: Push to ADO git
    runs-on: ubuntu-latest
    steps:
      - name: Checkout full history
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Push mirror to ADO
        run: |
          git remote add ado "https://eyal050:${ADO_MIRROR_PAT}@dev.azure.com/eyal050/guardianlink/_git/guardian-link"
          git push ado --mirror
        env:
          ADO_MIRROR_PAT: ${{ secrets.ADO_MIRROR_PAT }}
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/mirror-to-ado.yml
git commit -m "feat(ci): add GitHub→ADO git mirror workflow"
```

---

## Task 3: Create function-app pipeline template

**Files:** Create `pipelines/templates/function-app.yml`

The template uses `$(FUNCTION_APP_NAME)` — a pipeline variable that callers define by mapping from `guardianlink-infra-outputs`. The template links `guardianlink-infra-outputs` inside `deploy_dev` for App Insights name and resource group. Callers also link it at pipeline level to populate `FUNCTION_APP_NAME`.

For Azure auth, `AzureCLI@2` with `addSpnToEnvironment: true` injects `$servicePrincipalId`, `$tenantId`, `$subscriptionId`, and `$idToken` — used to set `ARM_*` env vars for Terraform steps. The function deploy steps only need `AzureCLI@2` (no ARM vars needed).

- [ ] **Step 1: Create pipelines directory and template**

```bash
mkdir -p pipelines/templates
```

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
        displayName: Install, lint, test
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

  - stage: deploy_dev
    displayName: Deploy to Dev
    dependsOn: build_test
    condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
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
                      --exclude "*.pyc" \
                      --exclude "__pycache__/*" \
                      --exclude "tests/*" \
                      --exclude "requirements-dev.txt"
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
                      az rest \
                        --method post \
                        --uri "https://management.azure.com${APP_RES_ID}/Annotations?api-version=2015-05-01" \
                        --body "{
                          \"Id\": \"$(uuidgen)\",
                          \"AnnotationName\": \"deploy-$(FUNCTION_APP_NAME)\",
                          \"EventTime\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
                          \"Category\": \"Deployment\",
                          \"Properties\": \"{\\\"ReleaseVersion\\\":\\\"$(DEPLOY_VERSION)\\\"}\"
                        }"

  - stage: deploy_prod
    displayName: Deploy to Prod (stub)
    dependsOn: deploy_dev
    condition: succeeded()
    jobs:
      - deployment: deploy_prod
        displayName: Prod deployment stub
        environment: prod
        pool:
          vmImage: ubuntu-latest
        strategy:
          runOnce:
            deploy:
              steps:
                - script: echo "Prod workspace not yet configured."
                  displayName: Prod stub
```

- [ ] **Step 2: Commit**

```bash
git add pipelines/templates/function-app.yml
git commit -m "feat(ci): add reusable function-app pipeline template"
```

---

## Task 4: Create Function App caller pipelines

**Files:** Create `pipelines/telemetry-writer.yml`, `pipelines/crash-classifier.yml`, `pipelines/notifier.yml`, `pipelines/metrics.yml`

Each caller links `guardianlink-infra-outputs` at pipeline level, maps `FUNCTION_APP_NAME` to the right variable from the group, and delegates everything else to the template. `$(FUNC_*_NAME)` is resolved from the variable group at queue time before the template's steps execute.

- [ ] **Step 1: Create telemetry-writer.yml**

```yaml
# pipelines/telemetry-writer.yml
trigger:
  branches:
    include:
      - main
  paths:
    include:
      - apps/telemetry-writer/**
      - pipelines/telemetry-writer.yml
      - pipelines/templates/function-app.yml

variables:
  - group: guardianlink-infra-outputs
  - name: FUNCTION_APP_NAME
    value: $(FUNC_TELEMETRY_WRITER_NAME)

stages:
  - template: templates/function-app.yml
    parameters:
      appDir: apps/telemetry-writer
```

- [ ] **Step 2: Create crash-classifier.yml**

```yaml
# pipelines/crash-classifier.yml
trigger:
  branches:
    include:
      - main
  paths:
    include:
      - apps/crash-classifier/**
      - pipelines/crash-classifier.yml
      - pipelines/templates/function-app.yml

variables:
  - group: guardianlink-infra-outputs
  - name: FUNCTION_APP_NAME
    value: $(FUNC_CRASH_CLASSIFIER_NAME)

stages:
  - template: templates/function-app.yml
    parameters:
      appDir: apps/crash-classifier
```

- [ ] **Step 3: Create notifier.yml**

```yaml
# pipelines/notifier.yml
trigger:
  branches:
    include:
      - main
  paths:
    include:
      - apps/notifier/**
      - pipelines/notifier.yml
      - pipelines/templates/function-app.yml

variables:
  - group: guardianlink-infra-outputs
  - name: FUNCTION_APP_NAME
    value: $(FUNC_NOTIFIER_NAME)

stages:
  - template: templates/function-app.yml
    parameters:
      appDir: apps/notifier
```

- [ ] **Step 4: Create metrics.yml**

```yaml
# pipelines/metrics.yml
trigger:
  branches:
    include:
      - main
  paths:
    include:
      - apps/metrics/**
      - pipelines/metrics.yml
      - pipelines/templates/function-app.yml

variables:
  - group: guardianlink-infra-outputs
  - name: FUNCTION_APP_NAME
    value: $(FUNC_METRICS_NAME)

stages:
  - template: templates/function-app.yml
    parameters:
      appDir: apps/metrics
```

- [ ] **Step 5: Commit**

```bash
git add pipelines/telemetry-writer.yml pipelines/crash-classifier.yml \
        pipelines/notifier.yml pipelines/metrics.yml
git commit -m "feat(ci): add function app caller pipelines"
```

---

## Task 5: Create infra pipeline

**Files:** Create `pipelines/infra.yml`

After `apply_dev`, a bash step reads `terraform output -json` and upserts `guardianlink-infra-outputs` via ADO REST API using `$(System.AccessToken)`. Enable **"Allow scripts to access the OAuth token"** in this pipeline's settings (Settings → General → Options) after registering it — steps will fail silently otherwise.

- [ ] **Step 1: Create pipelines/infra.yml**

```yaml
# pipelines/infra.yml
trigger:
  branches:
    include:
      - main
  paths:
    include:
      - terraform/guardianlink-dev/**
      - pipelines/infra.yml

variables:
  - group: guardianlink-backend

stages:
  - stage: validate
    displayName: Validate
    jobs:
      - job: validate
        displayName: fmt-check + validate
        pool:
          vmImage: ubuntu-latest
        steps:
          - task: AzureCLI@2
            displayName: Terraform init (no backend) + validate
            inputs:
              azureSubscription: guardianlink-azure
              scriptType: bash
              scriptLocation: inlineScript
              addSpnToEnvironment: true
              inlineScript: |
                cd terraform/guardianlink-dev
                export ARM_CLIENT_ID=$servicePrincipalId
                export ARM_TENANT_ID=$tenantId
                export ARM_SUBSCRIPTION_ID=$subscriptionId
                export ARM_USE_OIDC=true
                export ARM_OIDC_TOKEN=$idToken
                terraform init -backend=false -input=false
                terraform fmt -check -recursive
                terraform validate

  - stage: plan_dev
    displayName: Plan Dev
    dependsOn: validate
    condition: succeeded()
    jobs:
      - job: plan
        displayName: terraform plan
        pool:
          vmImage: ubuntu-latest
        steps:
          - task: AzureCLI@2
            displayName: Terraform init + plan
            inputs:
              azureSubscription: guardianlink-azure
              scriptType: bash
              scriptLocation: inlineScript
              addSpnToEnvironment: true
              inlineScript: |
                cd terraform/guardianlink-dev
                export ARM_CLIENT_ID=$servicePrincipalId
                export ARM_TENANT_ID=$tenantId
                export ARM_SUBSCRIPTION_ID=$subscriptionId
                export ARM_USE_OIDC=true
                export ARM_OIDC_TOKEN=$idToken
                terraform init \
                  -backend-config="resource_group_name=$(TF_BACKEND_RESOURCE_GROUP)" \
                  -backend-config="storage_account_name=$(TF_BACKEND_STORAGE_ACCOUNT)" \
                  -backend-config="container_name=$(TF_BACKEND_CONTAINER)" \
                  -backend-config="key=$(TF_BACKEND_STATE_KEY)" \
                  -input=false
                terraform plan -out="$(Build.ArtifactStagingDirectory)/tfplan" -input=false
          - publish: $(Build.ArtifactStagingDirectory)/tfplan
            artifact: tfplan-dev
            displayName: Publish plan artifact

  - stage: apply_dev
    displayName: Apply Dev
    dependsOn: plan_dev
    condition: succeeded()
    variables:
      SYSTEM_ACCESSTOKEN: $(System.AccessToken)
    jobs:
      - deployment: apply
        displayName: terraform apply + update infra-outputs
        environment: dev
        pool:
          vmImage: ubuntu-latest
        strategy:
          runOnce:
            deploy:
              steps:
                - checkout: self

                - download: current
                  artifact: tfplan-dev

                - task: AzureCLI@2
                  displayName: Terraform apply
                  inputs:
                    azureSubscription: guardianlink-azure
                    scriptType: bash
                    scriptLocation: inlineScript
                    addSpnToEnvironment: true
                    inlineScript: |
                      cd terraform/guardianlink-dev
                      export ARM_CLIENT_ID=$servicePrincipalId
                      export ARM_TENANT_ID=$tenantId
                      export ARM_SUBSCRIPTION_ID=$subscriptionId
                      export ARM_USE_OIDC=true
                      export ARM_OIDC_TOKEN=$idToken
                      terraform init \
                        -backend-config="resource_group_name=$(TF_BACKEND_RESOURCE_GROUP)" \
                        -backend-config="storage_account_name=$(TF_BACKEND_STORAGE_ACCOUNT)" \
                        -backend-config="container_name=$(TF_BACKEND_CONTAINER)" \
                        -backend-config="key=$(TF_BACKEND_STATE_KEY)" \
                        -input=false
                      terraform apply -input=false "$(Pipeline.Workspace)/tfplan-dev/tfplan"

                - task: AzureCLI@2
                  displayName: Update guardianlink-infra-outputs variable group
                  env:
                    SYSTEM_ACCESSTOKEN: $(System.AccessToken)
                  inputs:
                    azureSubscription: guardianlink-azure
                    scriptType: bash
                    scriptLocation: inlineScript
                    addSpnToEnvironment: true
                    inlineScript: |
                      cd terraform/guardianlink-dev
                      export ARM_CLIENT_ID=$servicePrincipalId
                      export ARM_TENANT_ID=$tenantId
                      export ARM_SUBSCRIPTION_ID=$subscriptionId
                      export ARM_USE_OIDC=true
                      export ARM_OIDC_TOKEN=$idToken
                      terraform init \
                        -backend-config="resource_group_name=$(TF_BACKEND_RESOURCE_GROUP)" \
                        -backend-config="storage_account_name=$(TF_BACKEND_STORAGE_ACCOUNT)" \
                        -backend-config="container_name=$(TF_BACKEND_CONTAINER)" \
                        -backend-config="key=$(TF_BACKEND_STATE_KEY)" \
                        -input=false

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

                      ADO_ORG="eyal050"
                      ADO_PROJECT="guardianlink"
                      VG_NAME="guardianlink-infra-outputs"
                      API="https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_apis/distributedtask"

                      VARIABLES=$(jq -n \
                        --arg rg "$RG" --arg appi "$APPI" \
                        --arg acr_s "$ACR_SERVER" --arg acr_n "$ACR_NAME" \
                        --arg tw "$FUNC_TW" --arg cc "$FUNC_CC" \
                        --arg not "$FUNC_NOT" --arg met "$FUNC_MET" \
                        --arg ca "$CA_ML" \
                        '{
                          RESOURCE_GROUP_NAME:        {value: $rg},
                          APP_INSIGHTS_NAME:          {value: $appi},
                          ACR_LOGIN_SERVER:           {value: $acr_s},
                          ACR_NAME:                   {value: $acr_n},
                          FUNC_TELEMETRY_WRITER_NAME: {value: $tw},
                          FUNC_CRASH_CLASSIFIER_NAME: {value: $cc},
                          FUNC_NOTIFIER_NAME:         {value: $not},
                          FUNC_METRICS_NAME:          {value: $met},
                          CONTAINER_APP_ML_STUB_NAME: {value: $ca}
                        }')

                      VG_RESP=$(curl -sf -u ":${SYSTEM_ACCESSTOKEN}" \
                        "${API}/variablegroups?groupName=${VG_NAME}&api-version=7.0")
                      VG_ID=$(echo "$VG_RESP" | jq -r '.value[0].id // empty')

                      if [ -n "$VG_ID" ]; then
                        PAYLOAD=$(jq -n \
                          --argjson id "$VG_ID" --arg name "$VG_NAME" \
                          --argjson vars "$VARIABLES" \
                          '{id: $id, name: $name, type: "Vsts", variables: $vars}')
                        curl -sf -u ":${SYSTEM_ACCESSTOKEN}" \
                          -X PUT -H "Content-Type: application/json" \
                          -d "$PAYLOAD" \
                          "${API}/variablegroups/${VG_ID}?api-version=7.0"
                        echo "Variable group ${VG_NAME} updated (id=${VG_ID})."
                      else
                        PAYLOAD=$(jq -n \
                          --arg name "$VG_NAME" --argjson vars "$VARIABLES" \
                          '{name: $name, type: "Vsts", variables: $vars}')
                        curl -sf -u ":${SYSTEM_ACCESSTOKEN}" \
                          -X POST -H "Content-Type: application/json" \
                          -d "$PAYLOAD" \
                          "${API}/variablegroups?api-version=7.0"
                        echo "Variable group ${VG_NAME} created."
                      fi

  - stage: plan_prod
    displayName: Plan Prod (stub)
    dependsOn: apply_dev
    condition: succeeded()
    jobs:
      - job: stub
        pool:
          vmImage: ubuntu-latest
        steps:
          - script: echo "Prod workspace not yet configured."
            displayName: Prod plan stub

  - stage: apply_prod
    displayName: Apply Prod (stub)
    dependsOn: plan_prod
    condition: succeeded()
    jobs:
      - deployment: apply_prod
        displayName: Prod apply stub
        environment: prod
        pool:
          vmImage: ubuntu-latest
        strategy:
          runOnce:
            deploy:
              steps:
                - script: echo "Prod workspace not yet configured."
                  displayName: Prod apply stub
```

- [ ] **Step 2: Commit**

```bash
git add pipelines/infra.yml
git commit -m "feat(ci): add Terraform infra pipeline with infra-outputs update"
```

---

## Task 6: Create ml-stub pipeline

**Files:** Create `pipelines/ml-stub.yml`

Uses `az acr build` (remote build on Azure) — no Docker daemon needed on the agent. Image is tagged with both the version string and `latest`.

- [ ] **Step 1: Create pipelines/ml-stub.yml**

```yaml
# pipelines/ml-stub.yml
trigger:
  branches:
    include:
      - main
  paths:
    include:
      - apps/ml-stub/**
      - pipelines/ml-stub.yml

variables:
  - group: guardianlink-infra-outputs

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
              pip install -r tests/requirements-test.txt -q 2>/dev/null \
                || pip install pytest httpx -q
              pytest tests/ -v
            displayName: Run tests

  - stage: build_push_dev
    displayName: Build, Push & Deploy to Dev
    dependsOn: build_test
    condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
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
                      az rest \
                        --method post \
                        --uri "https://management.azure.com${APP_RES_ID}/Annotations?api-version=2015-05-01" \
                        --body "{
                          \"Id\": \"$(uuidgen)\",
                          \"AnnotationName\": \"deploy-ml-stub\",
                          \"EventTime\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
                          \"Category\": \"Deployment\",
                          \"Properties\": \"{\\\"ReleaseVersion\\\":\\\"$(DEPLOY_VERSION)\\\"}\"
                        }"

  - stage: deploy_prod
    displayName: Deploy to Prod (stub)
    dependsOn: build_push_dev
    condition: succeeded()
    jobs:
      - deployment: deploy_prod
        environment: prod
        pool:
          vmImage: ubuntu-latest
        strategy:
          runOnce:
            deploy:
              steps:
                - script: echo "Prod workspace not yet configured."
                  displayName: Prod stub
```

- [ ] **Step 2: Commit**

```bash
git add pipelines/ml-stub.yml
git commit -m "feat(ci): add ml-stub ACR build + Container App deploy pipeline"
```

---

## Task 7: Create ADO setup script

**Files:** Create `scripts/setup-ado.sh`

This script is run once by the operator. It:
1. Creates the ADO `guardian-link` git repository
2. Creates an Azure AD app + service principal
3. Assigns `Owner` on the subscription to the SP
4. Creates the ADO WIF service connection (which returns the issuer + subject)
5. Creates the federated credential on the app using those values
6. Creates the `guardianlink-backend` variable group

**Prerequisites before running:** `az login` (must be authenticated), the 5 env vars below exported in the shell.

- [ ] **Step 1: Create scripts/setup-ado.sh**

```bash
#!/usr/bin/env bash
# One-time ADO setup: repo, WIF service connection, guardianlink-backend variable group.
# Prerequisites: az login, plus these env vars exported:
#   ADO_PAT                       ADO personal access token (Code:RW, Endpoints:RW, VarGroups:RW)
#   TF_BACKEND_RESOURCE_GROUP     resource group of the Terraform state SA
#   TF_BACKEND_STORAGE_ACCOUNT    storage account name
#   TF_BACKEND_CONTAINER          blob container name
#   TF_BACKEND_STATE_KEY          state file key (e.g. guardianlink-dev.tfstate)
set -euo pipefail

ADO_ORG="eyal050"
ADO_PROJECT="guardianlink"
ADO_BASE="https://dev.azure.com/${ADO_ORG}"
CONN_NAME="guardianlink-azure"
VG_NAME="guardianlink-backend"
SP_NAME="guardianlink-ado-pipeline"
REPO_NAME="guardian-link"

echo "==> Fetching ADO project ID..."
PROJECT_ID=$(curl -sf -u ":${ADO_PAT}" \
  "${ADO_BASE}/_apis/projects/${ADO_PROJECT}?api-version=7.0" | jq -r '.id')
echo "    Project ID: ${PROJECT_ID}"

echo "==> Creating ADO git repository '${REPO_NAME}'..."
REPO_RESP=$(curl -sf -u ":${ADO_PAT}" \
  -X POST -H "Content-Type: application/json" \
  -d "{\"name\":\"${REPO_NAME}\",\"project\":{\"id\":\"${PROJECT_ID}\"}}" \
  "${ADO_BASE}/${ADO_PROJECT}/_apis/git/repositories?api-version=7.0") || true
echo "    $(echo "$REPO_RESP" | jq -r '.remoteUrl // "repo may already exist"')"

echo "==> Fetching Azure subscription + tenant..."
SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "    Sub: ${SUB_NAME} (${SUB_ID}), Tenant: ${TENANT_ID}"

echo "==> Creating Azure AD app registration '${SP_NAME}'..."
APP_ID=$(az ad app create --display-name "$SP_NAME" --query appId -o tsv)
echo "    App (client) ID: ${APP_ID}"

echo "==> Creating service principal..."
SP_OBJ_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
echo "    SP object ID: ${SP_OBJ_ID}"

echo "==> Assigning Owner on subscription ${SUB_ID}..."
az role assignment create \
  --assignee "$APP_ID" \
  --role Owner \
  --scope "/subscriptions/${SUB_ID}" \
  --output none
echo "    Done."

echo "==> Creating ADO WIF service connection '${CONN_NAME}'..."
SC_PAYLOAD=$(jq -n \
  --arg name "$CONN_NAME" \
  --arg client_id "$APP_ID" \
  --arg tenant_id "$TENANT_ID" \
  --arg sub_id "$SUB_ID" \
  --arg sub_name "$SUB_NAME" \
  --arg proj_id "$PROJECT_ID" \
  --arg proj_name "$ADO_PROJECT" \
  '{
    name: $name,
    type: "AzureRM",
    url: "https://management.azure.com/",
    isShared: false,
    isReady: true,
    authorization: {
      scheme: "WorkloadIdentityFederation",
      parameters: {tenantid: $tenant_id, serviceprincipalid: $client_id}
    },
    data: {
      subscriptionId: $sub_id,
      subscriptionName: $sub_name,
      environment: "AzureCloud",
      scopeLevel: "Subscription",
      creationMode: "Manual"
    },
    serviceEndpointProjectReferences: [{
      name: $name,
      projectReference: {id: $proj_id, name: $proj_name}
    }]
  }')

SC_RESP=$(curl -sf -u ":${ADO_PAT}" \
  -X POST -H "Content-Type: application/json" \
  -d "$SC_PAYLOAD" \
  "${ADO_BASE}/${ADO_PROJECT}/_apis/serviceendpoint/endpoints?api-version=7.0")

ISSUER=$(echo "$SC_RESP" | jq -r '.authorization.parameters.workloadIdentityFederationIssuer')
SUBJECT=$(echo "$SC_RESP" | jq -r '.authorization.parameters.workloadIdentityFederationSubject')
SC_ID=$(echo "$SC_RESP" | jq -r '.id')
echo "    Service connection ID: ${SC_ID}"
echo "    Issuer:  ${ISSUER}"
echo "    Subject: ${SUBJECT}"

echo "==> Creating federated credential on app ${APP_ID}..."
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters "{
    \"name\": \"ado-${ADO_PROJECT}\",
    \"issuer\": \"${ISSUER}\",
    \"subject\": \"${SUBJECT}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" \
  --output none
echo "    Federated credential created."

echo "==> Creating variable group '${VG_NAME}'..."
VG_PAYLOAD=$(jq -n \
  --arg name "$VG_NAME" \
  --arg rg "$TF_BACKEND_RESOURCE_GROUP" \
  --arg sa "$TF_BACKEND_STORAGE_ACCOUNT" \
  --arg ct "$TF_BACKEND_CONTAINER" \
  --arg key "$TF_BACKEND_STATE_KEY" \
  '{
    name: $name,
    type: "Vsts",
    variables: {
      TF_BACKEND_RESOURCE_GROUP:   {value: $rg},
      TF_BACKEND_STORAGE_ACCOUNT:  {value: $sa},
      TF_BACKEND_CONTAINER:        {value: $ct},
      TF_BACKEND_STATE_KEY:        {value: $key}
    }
  }')

curl -sf -u ":${ADO_PAT}" \
  -X POST -H "Content-Type: application/json" \
  -d "$VG_PAYLOAD" \
  "${ADO_BASE}/${ADO_PROJECT}/_apis/distributedtask/variablegroups?api-version=7.0" \
  | jq '{id: .id, name: .name}'
echo "    Variable group created."

echo ""
echo "==> Setup complete."
echo "    Next steps:"
echo "    1. Add ADO_MIRROR_PAT as a GitHub Actions secret in the guardian-link repo."
echo "    2. Create ADO environments 'dev' and 'prod' under Pipelines → Environments."
echo "    3. Add a manual approval check to the 'prod' environment."
echo "    4. Register each pipeline YAML via: az devops pipeline create (see Task 9)."
echo "    5. On the infra pipeline: Settings → General → Enable 'Allow scripts to access OAuth token'."
```

- [ ] **Step 2: Make executable and commit**

```bash
chmod +x scripts/setup-ado.sh
git add scripts/setup-ado.sh
git commit -m "feat(ci): add one-time ADO setup script (SP, WIF, variable group)"
```

---

## Task 8: Push to GitHub and trigger first mirror

**Prerequisites:** All Tasks 1–7 committed and pushed.

- [ ] **Step 1: Push all commits to GitHub**

```bash
git push origin main
```

- [ ] **Step 2: Add ADO_MIRROR_PAT to GitHub secrets**

In GitHub: **Settings → Secrets and variables → Actions → New repository secret**
- Name: `ADO_MIRROR_PAT`
- Value: your ADO PAT (Code: Read & Write scope is sufficient for the mirror)

- [ ] **Step 3: Trigger the mirror**

Make a dummy commit or re-push to trigger the workflow:

```bash
git commit --allow-empty -m "chore: trigger mirror workflow"
git push origin main
```

- [ ] **Step 4: Verify mirror landed in ADO**

Check `https://dev.azure.com/eyal050/guardianlink/_git/guardian-link` — you should see all commits and the `pipelines/` directory.

---

## Task 9: Run setup script

**Prerequisites:** `az login` authenticated, `ADO_PAT` and all 4 `TF_BACKEND_*` values known.

- [ ] **Step 1: Export required env vars**

```bash
export ADO_PAT="<your-ado-pat>"
export TF_BACKEND_RESOURCE_GROUP="<rg-name>"
export TF_BACKEND_STORAGE_ACCOUNT="<sa-name>"
export TF_BACKEND_CONTAINER="<container-name>"
export TF_BACKEND_STATE_KEY="<state-key>"    # e.g. guardianlink-dev.tfstate
```

- [ ] **Step 2: Run the script**

```bash
bash scripts/setup-ado.sh
```

Expected output ends with `==> Setup complete.` and prints the next-steps list.

- [ ] **Step 3: Verify in ADO**

- `https://dev.azure.com/eyal050/guardianlink/_settings/adminservices` → service connection `guardianlink-azure` shows **Verified**
- `https://dev.azure.com/eyal050/guardianlink/_library` → variable group `guardianlink-backend` exists with 4 variables

---

## Task 10: Create ADO environments and register pipelines

- [ ] **Step 1: Create environments (ADO UI, ~2 min)**

Go to `https://dev.azure.com/eyal050/guardianlink/_environments`:
1. Create environment named `dev` — no approval required
2. Create environment named `prod` — add an **Approvals and checks → Approvals** check with your user as approver

- [ ] **Step 2: Register pipelines via Azure DevOps CLI**

```bash
az devops configure --defaults org=https://dev.azure.com/eyal050 project=guardianlink

for YAML in infra telemetry-writer crash-classifier notifier metrics ml-stub; do
  az devops pipeline create \
    --name "guardianlink-${YAML}" \
    --repository guardian-link \
    --repository-type tfsgit \
    --branch main \
    --yml-path "pipelines/${YAML}.yml"
  echo "Registered: guardianlink-${YAML}"
done
```

- [ ] **Step 3: Enable OAuth token on infra pipeline**

In ADO: open `guardianlink-infra` pipeline → **Edit → … → Triggers → YAML → Get sources** (or via pipeline settings gear) → check **"Allow scripts to access the OAuth token"**.

Alternatively via REST:

```bash
# Get pipeline ID
INFRA_ID=$(az devops pipeline show --name guardianlink-infra --query id -o tsv)

# Enable OAuth token
az devops invoke \
  --area pipelines \
  --resource pipelines \
  --route-parameters "pipelineId=${INFRA_ID}" \
  --http-method PATCH \
  --in-file /dev/stdin <<JSON
{"configuration": {"variables": {}, "options": [{"enabled": true, "definition": {"id": 12}}]}}
JSON
```

If that REST call is awkward, do it in the UI: pipeline → Edit → ⚙ (gear icon) → Options → check **Allow scripts to access the OAuth token** → Save.

- [ ] **Step 4: Authorise variable group access**

Run any pipeline once — ADO will prompt "This pipeline needs permission to access a resource". Click **Permit** for `guardianlink-backend` (and later `guardianlink-infra-outputs`). This is a one-time authorisation per pipeline per variable group.

---

## Task 11: Run infra pipeline and verify

- [ ] **Step 1: Trigger infra pipeline**

In ADO: `guardianlink-infra` → **Run pipeline** → Run.

- [ ] **Step 2: Watch stages complete**

Expected sequence: `validate` ✓ → `plan_dev` ✓ → `apply_dev` ✓ (auto, environment `dev`) → `plan_prod` ✓ (stub) → `apply_prod` waits for approval → approve or skip.

- [ ] **Step 3: Verify guardianlink-infra-outputs was populated**

Go to `https://dev.azure.com/eyal050/guardianlink/_library` → `guardianlink-infra-outputs`. You should see all 9 variables (`RESOURCE_GROUP_NAME`, `APP_INSIGHTS_NAME`, `ACR_LOGIN_SERVER`, etc.) populated with real values.

- [ ] **Step 4: Smoke-test a function pipeline**

Trigger `guardianlink-telemetry-writer` manually. Expected: `build_test` runs pytest → `deploy_dev` packages and deploys → `DEPLOY_VERSION` app setting appears in the Function App's Configuration blade → resource tag `deploy-version` visible in the Tags blade.

---

## Known constraints

- **First infra apply requires `ml-stub:latest` to exist in ACR.** The Container App resource (`ml-stub.tf`) references `ml-stub:latest` on initial create. Run a targeted apply first (`-target=azurerm_container_registry.main`), then run the ml-stub pipeline once to push the image, then run the full infra apply. Subsequent infra applies ignore the image (`lifecycle.ignore_changes`).
- App pipelines will error at deploy stages if `guardianlink-infra-outputs` is empty (Task 11 must run first).
- Each pipeline requires one-time variable group authorisation on first run (ADO prompts inline).
- The `guardianlink-backend` variable group must have "Allow access to all pipelines" enabled in Library settings, or each pipeline must be individually authorised.
- `$(FUNC_*_NAME)` macro resolution in caller `variables:` depends on variable group expansion at queue time. This is standard ADO behaviour and works as long as the group is linked at pipeline level.
