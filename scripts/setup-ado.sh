#!/usr/bin/env bash
# One-time ADO setup: repo, WIF service connection, guardianlink-backend variable group.
# Prerequisites: az login, plus these env vars exported:
#   ADO_PAT                       ADO personal access token (Code:RW, Endpoints:RW, VarGroups:RW)
#   TF_BACKEND_RESOURCE_GROUP     resource group of the Terraform state SA
#   TF_BACKEND_STORAGE_ACCOUNT    storage account name
#   TF_BACKEND_CONTAINER          blob container name
#   TF_BACKEND_STATE_KEY          state file key (e.g. guardianlink-dev.tfstate)
set -euo pipefail

py() { python3 -c "$@"; }
json_get()  { py "import sys,json; d=json.load(sys.stdin); print($1)"; }
json_gets() { py "import sys,json; d=json.load(sys.stdin); $1"; }

ADO_ORG="eyal050"
ADO_PROJECT="guardianlink"
ADO_BASE="https://dev.azure.com/${ADO_ORG}"
CONN_NAME="guardianlink-azure"
VG_NAME="guardianlink-backend"
SP_NAME="guardianlink-ado-pipeline"
REPO_NAME="guardian-link"

echo "==> Fetching ADO project ID..."
PROJECT_ID=$(curl -sf -u ":${ADO_PAT}" \
  "${ADO_BASE}/_apis/projects/${ADO_PROJECT}?api-version=7.0" \
  | json_get "d['id']")
echo "    Project ID: ${PROJECT_ID}"

echo "==> Creating ADO git repository '${REPO_NAME}'..."
REPO_RESP=$(curl -sf -u ":${ADO_PAT}" \
  -X POST -H "Content-Type: application/json" \
  -d "{\"name\":\"${REPO_NAME}\",\"project\":{\"id\":\"${PROJECT_ID}\"}}" \
  "${ADO_BASE}/${ADO_PROJECT}/_apis/git/repositories?api-version=7.0") || true
echo "    $(echo "$REPO_RESP" | json_get "d.get('remoteUrl','repo may already exist')")"

echo "==> Fetching Azure subscription + tenant..."
SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "    Sub: ${SUB_NAME} (${SUB_ID}), Tenant: ${TENANT_ID}"

echo "==> Creating Azure AD app registration '${SP_NAME}'..."
APP_ID=$(az ad app create --display-name "$SP_NAME" --query appId -o tsv)
echo "    App (client) ID: ${APP_ID}"

echo "==> Creating service principal..."
az ad sp create --id "$APP_ID" --output none
echo "    Done."

echo "==> Assigning Owner on subscription ${SUB_ID}..."
az role assignment create \
  --assignee "$APP_ID" \
  --role Owner \
  --scope "/subscriptions/${SUB_ID}" \
  --output none
echo "    Done."

echo "==> Creating ADO WIF service connection '${CONN_NAME}'..."
SC_PAYLOAD=$(CONN_NAME="$CONN_NAME" APP_ID="$APP_ID" TENANT_ID="$TENANT_ID" \
             SUB_ID="$SUB_ID" SUB_NAME="$SUB_NAME" \
             PROJECT_ID="$PROJECT_ID" ADO_PROJECT="$ADO_PROJECT" \
  python3 -c "
import json, os
e = os.environ
print(json.dumps({
  'name': e['CONN_NAME'],
  'type': 'AzureRM',
  'url': 'https://management.azure.com/',
  'isShared': False,
  'isReady': True,
  'authorization': {
    'scheme': 'WorkloadIdentityFederation',
    'parameters': {'tenantid': e['TENANT_ID'], 'serviceprincipalid': e['APP_ID']}
  },
  'data': {
    'subscriptionId': e['SUB_ID'],
    'subscriptionName': e['SUB_NAME'],
    'environment': 'AzureCloud',
    'scopeLevel': 'Subscription',
    'creationMode': 'Manual'
  },
  'serviceEndpointProjectReferences': [{
    'name': e['CONN_NAME'],
    'projectReference': {'id': e['PROJECT_ID'], 'name': e['ADO_PROJECT']}
  }]
}))")

SC_RESP=$(curl -sf -u ":${ADO_PAT}" \
  -X POST -H "Content-Type: application/json" \
  -d "$SC_PAYLOAD" \
  "${ADO_BASE}/${ADO_PROJECT}/_apis/serviceendpoint/endpoints?api-version=7.0")

ISSUER=$(echo "$SC_RESP"  | json_get "d['authorization']['parameters']['workloadIdentityFederationIssuer']")
SUBJECT=$(echo "$SC_RESP" | json_get "d['authorization']['parameters']['workloadIdentityFederationSubject']")
SC_ID=$(echo "$SC_RESP"   | json_get "d['id']")
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
VG_PAYLOAD=$(VG_NAME="$VG_NAME" PROJECT_ID="$PROJECT_ID" ADO_PROJECT="$ADO_PROJECT" \
             RG="$TF_BACKEND_RESOURCE_GROUP" SA="$TF_BACKEND_STORAGE_ACCOUNT" \
             CT="$TF_BACKEND_CONTAINER" KEY="$TF_BACKEND_STATE_KEY" \
  python3 -c "
import json, os
e = os.environ
print(json.dumps({
  'name': e['VG_NAME'],
  'type': 'Vsts',
  'variables': {
    'TF_BACKEND_RESOURCE_GROUP':  {'value': e['RG']},
    'TF_BACKEND_STORAGE_ACCOUNT': {'value': e['SA']},
    'TF_BACKEND_CONTAINER':       {'value': e['CT']},
    'TF_BACKEND_STATE_KEY':       {'value': e['KEY']}
  },
  'variableGroupProjectReferences': [{
    'name': e['VG_NAME'],
    'projectReference': {'id': e['PROJECT_ID'], 'name': e['ADO_PROJECT']}
  }]
}))")

VG_RESP=$(curl -sf -u ":${ADO_PAT}" \
  -X POST -H "Content-Type: application/json" \
  -d "$VG_PAYLOAD" \
  "${ADO_BASE}/${ADO_PROJECT}/_apis/distributedtask/variablegroups?api-version=7.0")
echo "    $(echo "$VG_RESP" | json_get "f\"id={d['id']} name={d['name']}\"")"
echo "    Variable group created."

echo ""
echo "==> Setup complete."
echo "    Next steps:"
echo "    1. Create ADO environments 'dev' and 'prod' under Pipelines → Environments."
echo "    2. Add a manual approval check to the 'prod' environment."
echo "    3. Register each pipeline YAML via: az devops pipeline create."
echo "    4. On the infra pipeline: Settings → General → Enable 'Allow scripts to access OAuth token'."
