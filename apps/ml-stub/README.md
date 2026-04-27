# GuardianLink ml-stub Container App

Minimal Python HTTP server that stubs the crash-classification ML model:

```
POST /classify   →  {"is_crash": true, "confidence": 0.95}
GET  /healthz    →  200 ok
```

No dependencies beyond the Python stdlib.

## Deploy (two-step — image must exist in ACR before Container App starts)

```bash
cd terraform/guardianlink-dev

# Step 1 — provision ACR and the Container App Environment
terraform apply \
  -target=azurerm_container_registry.main \
  -target=azurerm_container_app_environment.main \
  -auto-approve

# Step 2 — build and push the image using ACR Tasks (runs in Azure, no local Docker needed)
ACR_NAME=$(terraform output -raw acr_name)
az acr build \
  --registry "$ACR_NAME" \
  --image ml-stub:latest \
  ../../apps/ml-stub

# Step 3 — apply everything (Container App + wire ML_ENDPOINT_URL into classifier)
terraform apply -auto-approve
```

## Re-deploy after code changes

```bash
ACR_NAME=$(terraform output -raw acr_name)
ML_FQDN=$(terraform output -raw ml_stub_fqdn)

az acr build --registry "$ACR_NAME" --image ml-stub:latest ../../apps/ml-stub
az containerapp update \
  -g rg-guardianlink-dev \
  -n ca-guardianlink-dev-weu-ml-stub \
  --image "${ACR_NAME}.azurecr.io/ml-stub:latest"
```

## Verify

```bash
curl https://$(terraform output -raw ml_stub_fqdn)/healthz
curl -X POST https://$(terraform output -raw ml_stub_fqdn)/classify \
  -H "Content-Type: application/json" \
  -d '{"events": []}'
```

## Tests

```bash
cd apps/ml-stub
python3 -m pytest tests/ -v
```
