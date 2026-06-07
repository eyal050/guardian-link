# Hands-On Lab: AKS + Helm + ArgoCD on GuardianLink

A practical lab to convert "theoretical" into "I've run this," structured as a feature branch on GuardianLink. By the end you'll have deployed one of your existing GuardianLink workloads to AKS via a Helm chart you authored, managed by ArgoCD with GitOps, secrets pulled from Key Vault — and you'll have deliberately broken and fixed it.

**This does double duty:** it closes your interview gap AND completes the AKS workload that's been sitting on your GuardianLink Phase 2 to-do list. After this, "I built an AKS + Helm + ArgoCD setup with Key Vault-backed secrets and GitOps" is literally true and demonstrable.

**Time:** 2–3 focused evenings, or one weekend.
**Cost:** A small AKS cluster + ACR runs roughly €3–8/day. **Delete it when done** (`az group delete`) — don't leave it running.

---

## Setup: the branch

```bash
cd guardian-link
git checkout -b feature/aks-gitops
mkdir -p k8s/charts k8s/argocd k8s/aks-terraform docs
```

Pick **one** existing GuardianLink workload to containerize and deploy — the **consumer** (Event Hub inspector) is ideal: it's a long-running process (fits a pod better than a Function), it has a real dependency (Event Hub) to wire through Key Vault, and it's simple enough to debug.

---

## Phase 1 — Provision AKS (evening 1, ~2 hrs)

Goal: a working AKS cluster with the integrations this role names (AKS, ACR, Key Vault, OIDC, Workload Identity).

### 1.1 Terraform module for AKS
Create `k8s/aks-terraform/` (or extend your existing modules):

```hcl
# Key resources to include:
# - azurerm_kubernetes_cluster with:
#     oidc_issuer_enabled         = true
#     workload_identity_enabled   = true
#     a default system node pool (1-2 nodes, Standard_B2s to keep cost low)
#     azure_active_directory_role_based_access_control
# - azurerm_container_registry (Basic SKU)
# - role assignment: AKS kubelet identity -> AcrPull on the ACR
# - azurerm_user_assigned_identity (for workload identity)
# - azurerm_federated_identity_credential linking the UAI to a K8s service account
# - Key Vault access: role assignment "Key Vault Secrets User" to the UAI
```

**Checklist:**
- [ ] `terraform apply` brings up AKS + ACR
- [ ] `az aks get-credentials` — `kubectl get nodes` shows Ready nodes
- [ ] ACR attached (`az aks check-acr` or verify the AcrPull role assignment)
- [ ] OIDC issuer URL retrievable (`az aks show --query oidcIssuerProfile.issuerUrl`)
- [ ] Document the decision in `docs/` — *why* AKS for the consumer when the rest is PaaS (the "long-running connection fits a pod better than Functions' execution model" rationale)

### 1.2 Enable the Key Vault CSI add-on
- [ ] Enable `azure-keyvault-secrets-provider` add-on (via Terraform `key_vault_secrets_provider` block or `az aks enable-addons`)
- [ ] Confirm the CSI driver pods are running in `kube-system`

---

## Phase 2 — Containerize + Helm chart (evening 2, ~2-3 hrs)

This is the **Helm authoring** rep — the named hard requirement.

### 2.1 Containerize the consumer
- [ ] Write a `Dockerfile` for `apps/consumer/` (Python slim base, non-root user, read-only rootfs where possible)
- [ ] Build and push to ACR: `az acr build -t guardianlink/consumer:0.1.0 -r <acr> .`

### 2.2 Author a Helm chart from scratch (don't `helm create` and leave the boilerplate — write it deliberately)
Create `k8s/charts/consumer/`:
- [ ] `Chart.yaml` — name, version 0.1.0, appVersion matching the image
- [ ] `values.yaml` — image repo/tag, replicaCount, resources, env, serviceAccount name, keyVault config
- [ ] `templates/deployment.yaml` — templated; use `{{ .Values... }}`, proper `nindent`, a `_helpers.tpl` for labels
- [ ] `templates/serviceaccount.yaml` — annotated with the Workload Identity client ID
- [ ] `templates/secretproviderclass.yaml` — the Key Vault CSI SecretProviderClass pulling the Event Hub connection (or better, the values needed for managed-identity auth)
- [ ] `_helpers.tpl` — a named template for common labels, included everywhere
- [ ] `values-dev.yaml` — environment override (deliberately practice the layered-values pattern)

**Deliberately practice the gotchas** so they're muscle memory for the interview:
- [ ] Hit a whitespace/indent bug, see the broken YAML, fix it with `nindent`
- [ ] Use `helm template . -f values-dev.yaml` to debug rendering BEFORE deploying
- [ ] Use `helm lint`

### 2.3 First manual deploy (before GitOps)
- [ ] `helm upgrade --install consumer ./k8s/charts/consumer -f values-dev.yaml -n guardianlink --create-namespace`
- [ ] `kubectl get pods` — watch it come up
- [ ] Confirm the Key Vault CSI secret mounted: `kubectl exec` into the pod and check the mount path
- [ ] Confirm the consumer connects to Event Hub using the Workload-Identity-backed credential

**If you get the pod running with a Key Vault secret mounted via Workload Identity, you've already cleared the single biggest interview gap.**

---

## Phase 3 — ArgoCD + GitOps (evening 3, ~2-3 hrs)

The named GitOps requirement.

### 3.1 Install ArgoCD
- [ ] `kubectl create namespace argocd`
- [ ] `kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`
- [ ] Port-forward and log into the UI; get the initial admin password
- [ ] Install the `argocd` CLI

### 3.2 Point ArgoCD at your repo
Create `k8s/argocd/consumer-app.yaml` — an `Application` resource:
- [ ] `source`: your GuardianLink repo, path `k8s/charts/consumer`, with `helm.valueFiles: [values-dev.yaml]`
- [ ] `destination`: in-cluster, namespace `guardianlink`
- [ ] `syncPolicy.automated` with `prune: true`, `selfHeal: true`
- [ ] Apply it: `kubectl apply -f k8s/argocd/consumer-app.yaml -n argocd`
- [ ] Watch ArgoCD sync the app — see it go Synced + Healthy in the UI

### 3.3 Prove the GitOps loop
- [ ] Change `replicaCount` in `values-dev.yaml`, commit, push → watch ArgoCD auto-sync the change
- [ ] Manually `kubectl scale` the deployment to a different number → watch **selfHeal** revert it back to Git state (this is the "aha" moment — feel it happen)
- [ ] Observe the difference between **Synced** and **Healthy** in the UI

### 3.4 (Stretch) ApplicationSet
- [ ] Convert the single Application into an ApplicationSet with a list generator producing dev + staging variants. Even a toy version teaches the multi-team scaling pattern you'd describe at Mapal.

---

## Phase 4 — Break it on purpose (the part that makes it real)

This is your failure-injection methodology applied to the new stack. Each one is a story you can tell in the interview ("I've debugged that — here's how"). Time yourself; write down the diagnostic path.

- [ ] **Break the Key Vault RBAC**: remove the "Key Vault Secrets User" role from the UAI. Redeploy. Watch the pod stick in `ContainerCreating` with a FailedMount. Diagnose via `kubectl describe pod`. Fix.
- [ ] **Break Workload Identity**: change the federated credential subject so it doesn't match the service account. Watch the auth fail. Diagnose.
- [ ] **OOMKill it**: set the memory limit absurdly low. Watch `OOMKilled` in `kubectl describe`. Fix the limit.
- [ ] **ImagePullBackOff**: reference a non-existent image tag. See the event. Fix.
- [ ] **Stall a drain**: set a PDB with minAvailable == replicas, then try to drain a node. Watch it hang. Explain why.
- [ ] **Break DNS egress**: apply a NetworkPolicy that forgets to allow port 53 to kube-dns. Watch everything break confusingly. Fix. (The classic gotcha.)
- [ ] **ArgoCD drift**: manually edit a live resource, watch selfHeal fight you, then disable selfHeal and watch it report OutOfSync instead.

For each: note **symptom → where you looked → root cause → fix**. Add them to your GuardianLink `docs/failure-scenarios.md` as AKS/GitOps scenarios — extends the catalog you already wrote about publicly.

---

## Phase 5 — Document + merge

- [ ] Write `docs/aks-gitops.md`: architecture (consumer on AKS, Helm-packaged, ArgoCD-managed, Key Vault secrets via CSI + Workload Identity), the decision rationale, and the failure scenarios you exercised
- [ ] Update the root README architecture section to show the AKS workload alongside the PaaS ones
- [ ] Update the architecture diagram (the Mermaid one) to include the AKS path
- [ ] Commit, push, open a PR on the branch (even if you self-merge — it's good hygiene and shows in the repo history)
- [ ] **`az group delete`** the lab resources once you've captured screenshots/notes — don't burn money on an idle cluster

---

## What this gives you for the interview

After this lab, you can honestly say — and back up — every one of these:

1. "I provisioned AKS via Terraform with OIDC and Workload Identity enabled."
2. "I authored Helm charts from scratch, including a SecretProviderClass and a Workload-Identity-bound service account, with layered per-environment values."
3. "I manage deployments with ArgoCD — automated sync, selfHeal, prune — and I've seen drift correction in action."
4. "Secrets come from Key Vault via the CSI driver, never committed to Git."
5. "I've debugged the real failure modes — failed CSI mounts from missing RBAC, Workload Identity subject mismatches, OOMKills, stalled drains from bad PDBs, DNS-egress NetworkPolicy mistakes — because I deliberately injected them."

That last point is the differentiator. Almost no candidate for this role will have *deliberately broken* a Key Vault CSI mount and debugged it. You'll have done it last week.

And your honest framing shifts from "my AKS is theoretical" to "I've been building this hands-on — here's the repo." That's a categorically stronger position than where the N-iX feedback left you.

---

## Sequencing note

If the Mapal technical interview is **less than a week away**, do Phases 1–3 minimum (get the thing running end-to-end) and at least 2–3 of the Phase 4 breakages. The breakages matter more than the stretch goals — debugging stories are what sell.

If you have **more than a week**, do all of it including the ApplicationSet, and write it up properly. The written `docs/aks-gitops.md` + updated diagram also strengthens the repo for every other application and recruiter.
