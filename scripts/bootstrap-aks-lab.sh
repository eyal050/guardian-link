#!/usr/bin/env bash
# Re-bootstrap the AKS + Helm + ArgoCD lab after a fresh `terraform apply`.
#
# Run this AFTER `terraform apply` succeeds in terraform/environments/dev.
# Idempotent — safe to re-run. Tears down with `terraform destroy` (or
# `az group delete -n rg-guardianlink-dev`); everything below is recreated.
#
#   ./scripts/bootstrap-aks-lab.sh
#
# Steps:
#   1. az aks get-credentials for the dev cluster
#   2. build + push the consumer and producer images to ACR (tags read from the
#      chart values-dev.yaml, so they match exactly what ArgoCD will deploy)
#   3. install ArgoCD (server-side apply; idempotent)
#   4. apply the ArgoCD Application manifests
#   5. inject the per-rebuild dynamic values (the two managed-identity client
#      ids and the random-suffixed storage URL) as ArgoCD helm parameters,
#      read fresh from terraform outputs — these change on every apply, so the
#      committed values-dev.yaml can't be trusted for them.
set -euo pipefail

# --- config: dev defaults, override via env ---------------------------------
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-e1d66dab-ec62-411c-85b2-c5b3b4f41334}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-guardianlink-dev}"
AKS_CLUSTER="${AKS_CLUSTER:-aks-guardianlink-dev-weu}"
ACR_NAME="${ACR_NAME:-acrguardianlinkdevweu}"

# terraform state backend (needed to read outputs); stable across rebuilds
export ARM_SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:-c770b313-1ad0-4dce-864b-f083acbfba68}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
TF_DIR="terraform/environments/dev"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# Extract the image tag from a chart's values-dev.yaml (image: -> tag:).
chart_image_tag() {
  grep -A4 '^image:' "$1/values-dev.yaml" | grep -m1 'tag:' \
    | sed -E 's/.*tag:[[:space:]]*"?([^"#]+)"?.*/\1/' | tr -d '[:space:]'
}

tfout() { terraform -chdir="$TF_DIR" output -raw "$1"; }

# --- 1. cluster credentials -------------------------------------------------
log "Fetching AKS credentials ($AKS_CLUSTER)"
az aks get-credentials -n "$AKS_CLUSTER" -g "$RESOURCE_GROUP" \
  --subscription "$SUBSCRIPTION_ID" --overwrite-existing

# --- 2. build + push images (tags must match the charts) --------------------
CONSUMER_TAG="$(chart_image_tag k8s/charts/consumer)"
PRODUCER_TAG="$(chart_image_tag k8s/charts/producer)"
log "Building consumer:${CONSUMER_TAG}"
az acr build -t "consumer:${CONSUMER_TAG}" -r "$ACR_NAME" --subscription "$SUBSCRIPTION_ID" apps/consumer
log "Building producer:${PRODUCER_TAG}"
az acr build -t "producer:${PRODUCER_TAG}" -r "$ACR_NAME" --subscription "$SUBSCRIPTION_ID" apps/simulator

# --- 3. install ArgoCD ------------------------------------------------------
log "Installing/updating ArgoCD"
kubectl get namespace argocd >/dev/null 2>&1 || kubectl create namespace argocd
# --server-side avoids the large-CRD annotation limit on plain apply.
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
log "Waiting for ArgoCD components"
kubectl wait --for=condition=available --timeout=300s \
  deploy/argocd-server deploy/argocd-repo-server deploy/argocd-applicationset-controller -n argocd

# --- 4. read per-rebuild dynamic values -------------------------------------
log "Reading dynamic values from terraform outputs"
CONSUMER_CID="$(tfout consumer_identity_client_id)"
PRODUCER_CID="$(tfout producer_identity_client_id)"
STORAGE_URL="$(tfout storage_blob_url)"

# --- 5. apply Applications + inject the dynamic values ----------------------
log "Applying ArgoCD Applications"
kubectl apply -f k8s/argocd/consumer-app.yaml -f k8s/argocd/producer-app.yaml

# Helm parameters override valueFiles, so these win over the committed
# (now-stale) clientId / storage URL until you next regenerate them.
log "Injecting fresh identity + storage values as helm parameters"
kubectl patch application consumer -n argocd --type merge -p "{\"spec\":{\"source\":{\"helm\":{\"parameters\":[{\"name\":\"workloadIdentity.clientId\",\"value\":\"${CONSUMER_CID}\"},{\"name\":\"storage.blobAccountUrl\",\"value\":\"${STORAGE_URL}\"}]}}}}"
kubectl patch application producer -n argocd --type merge -p "{\"spec\":{\"source\":{\"helm\":{\"parameters\":[{\"name\":\"workloadIdentity.clientId\",\"value\":\"${PRODUCER_CID}\"}]}}}}"

log "Bootstrap complete. ArgoCD will sync within its reconcile interval."
printf 'ArgoCD admin password: '
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
echo "UI: kubectl port-forward svc/argocd-server -n argocd 8080:443  ->  https://localhost:8080 (user: admin)"
