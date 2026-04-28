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
