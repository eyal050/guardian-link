# Branching Strategy: Dev/Main Split with Per-Branch ADO Deployment

**Date:** 2026-05-17
**Scope:** GitHub branching workflow, GH→ADO mirror, ADO pipeline triggers, branch protection
**Supersedes parts of:** [2026-04-28-ado-pipelines-design.md](2026-04-28-ado-pipelines-design.md) (section 1, "GitHub → ADO Git Mirroring")

---

## Motivation

Today every deployment runs through a single chain: a push to GitHub `main` mirrors to ADO, which fires `infra.yml` that applies dev → waits at ADO env approval → applies prod. App pipelines follow the same dev-then-prod chain. There is no fast-iteration path: any change you want to see running in the dev environment must go through `main`, which is also the prod source of truth.

The new model gives each environment its own GitHub branch:

- **`dev` branch** — developers commit directly or via PR. Every push mirrors to ADO `dev` and triggers the dev side of every pipeline. Fast feedback.
- **`main` branch** — only updated via merged PR from `dev` (or another branch). The merge mirrors to ADO `main` and triggers the prod side of every pipeline, still gated by ADO environment approval.

"What is in prod" becomes identical to "what is on `main`", and prod deploys happen as a side effect of merging — exactly when code review happens.

---

## 1. GitHub Actions (`.github/workflows/mirror-to-ado.yml`)

Replace today's single-trigger, push-all workflow with a branch-aware, selective-push workflow:

```yaml
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
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          ref: ${{ github.ref }}

      - name: Push branch + tags to ADO
        run: |
          BRANCH="${{ github.ref_name }}"
          git remote add ado "https://eyal050:${ADO_MIRROR_PAT}@dev.azure.com/eyal050/guardianlink/_git/guardian-link"
          git push ado "HEAD:refs/heads/${BRANCH}" --force-with-lease
          git push ado --tags
        env:
          ADO_MIRROR_PAT: ${{ secrets.ADO_MIRROR_PAT }}
```

**Key behaviors:**

- A push to `dev` (direct or via PR merge into dev) mirrors **only** `dev`.
- A push to `main` (always via PR merge) mirrors **only** `main`.
- Nothing else is mirrored. Feature branches, `public-prep`, etc. stay GitHub-only.
- `--force-with-lease` (not plain `--force`) — if someone unexpectedly pushed directly to ADO, this fails loudly instead of silently clobbering.
- `workflow_dispatch` retained for manual re-mirror when needed.

**One-way mirror invariant:** GitHub is the source of truth. Direct commits to ADO are not supported — they will be overwritten on the next mirror push. Documented in the repo README; not enforced via ADO branch lock (see Section 3b).

---

## 2. ADO Pipeline Restructuring

### 2a. `pipelines/infra.yml`

**Trigger** — add `dev` to `branches.include`:

```yaml
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
```

**Stages** — wrap the dev block and prod block in branch-aware compile-time conditions:

```yaml
stages:
  - ${{ if and(eq(parameters.action, 'apply'),
               eq(variables['Build.SourceBranch'], 'refs/heads/dev')) }}:
    # apply_dev (via terraform-env.yml template) + post_apply_dev
    # post_apply_dev writes outputs to guardianlink-infra-outputs
    # and POSTs app-pipeline runs targeting refs/heads/dev

  - ${{ if and(eq(parameters.action, 'apply'),
               eq(variables['Build.SourceBranch'], 'refs/heads/main')) }}:
    # apply_prod (via terraform-env.yml template) + post_apply_prod
    # post_apply_prod writes outputs to guardianlink-infra-outputs-prod
    # and POSTs app-pipeline runs targeting refs/heads/main
```

The existing `post_apply_dev` stage's logic (terraform output → upsert variable group → trigger app pipelines) is duplicated as `post_apply_prod` with two differences:

1. The `VG_NAME` becomes `guardianlink-infra-outputs-prod` (new VG, see 2c).
2. The pipeline trigger PAYLOAD `refName` becomes `refs/heads/main`.

**Destroy action** mirrors the apply pattern — destroy on `dev` branch destroys dev only; destroy on `main` destroys prod only. The current dev-then-prod destroy chain is removed (it was unsafe by design — running destroy on the wrong env could happen).

### 2b. `pipelines/templates/function-app.yml`

Today, `deploy_dev` is runtime-gated on `eq(variables['Build.SourceBranch'], 'refs/heads/main')` and `deploy_prod` is a stub.

New model — compile-time branch gating, real prod deploy:

```yaml
stages:
  - stage: build_test
    # unchanged

  - ${{ if eq(variables['Build.SourceBranch'], 'refs/heads/dev') }}:
    - stage: deploy_dev
      dependsOn: build_test
      variables:
        - group: guardianlink-infra-outputs
      jobs:
        - deployment: deploy
          environment: dev
          # existing deploy steps, unchanged

  - ${{ if eq(variables['Build.SourceBranch'], 'refs/heads/main') }}:
    - stage: deploy_prod
      dependsOn: build_test
      variables:
        - group: guardianlink-infra-outputs-prod
      jobs:
        - deployment: deploy
          environment: prod
          # same steps as deploy_dev, just reading prod variable group
```

The prod stage uses the same step body as dev — the only thing that changes is which variable group is consumed.

### 2c. Per-app pipeline files

`pipelines/telemetry-writer.yml`, `crash-classifier.yml`, `notifier.yml`, `metrics.yml`, `ml-stub.yml`, `aks-consumer.yml` each get the same trigger update:

```yaml
trigger:
  branches:
    include:
      - dev
      - main
  paths:
    include:
      - apps/{appname}/**
      - pipelines/{appname}.yml
      - pipelines/templates/function-app.yml  # for function apps only
```

Pipelines that don't use the `function-app.yml` template (`ml-stub`, `aks-consumer`) follow the same per-branch deploy-stage pattern in their own bodies.

**`pipelines/tests.yml` — special case.** Currently uses a `pr:` trigger on dev/main. ADO `pr:` triggers only fire when a PR is opened *in ADO*; since GitHub owns PRs in this workflow, `tests.yml` has effectively been dead since the mirror was set up. Convert it to a branch `trigger:` on `dev` and `main` so cross-cutting unit tests actually run on every push to either branch. No deploy stages — test results only.

### 2d. New variable group: `guardianlink-infra-outputs-prod`

Same shape as `guardianlink-infra-outputs` (created/updated by `infra.yml`'s post-apply step), with prod resource names. Populated by `post_apply_prod` after the first successful prod apply. Created empty as a one-time setup step before the first prod run.

App pipelines reference the dev VG in their `deploy_dev` stage and the prod VG in their `deploy_prod` stage (see 2b).

### 2e. ADO environment approvals

Existing approvals on the `dev` and `prod` ADO environments are kept in place. Belt-and-suspenders:

- Code review on the PR to `main` is the first gate.
- ADO `prod` env approval is the second gate, just before `terraform apply` runs.

A broken `terraform plan` discovered post-merge fails the plan stage; the env approval is never reached; nothing applies.

---

## 3. Branch Protection & Cleanup

### 3a. GitHub branch protection on `main`

Configured via GitHub UI (Settings → Branches → Add rule for `main`):

| Rule | Value |
|---|---|
| Require a pull request before merging | enabled |
| Required approving reviews | 1 |
| Dismiss stale reviews on new commits | enabled |
| Require linear history | enabled (no merge commits — keeps the mirror diff clean) |
| Restrict who can push directly | only repo admins |
| Allow force pushes | disabled |
| Allow deletions | disabled |

`dev` remains unprotected — direct pushes allowed for fast iteration.

### 3b. ADO repo write access

**Soft model (default for this rollout):** document in README that GitHub is the source of truth and ADO is mirror-only. The `--force-with-lease` in the mirror workflow will fail loudly if anyone has pushed directly to ADO since the last mirror, surfacing the issue rather than silently clobbering.

**Hard model (deferred):** make `dev` and `main` on the ADO repo read-only for everyone except the mirror PAT identity. Adds friction for emergency in-ADO hotfixes; not worth it while you're solo.

### 3c. Cleanup

- **Delete `public-prep`** on both `origin` (GitHub) and `ado` remotes. Confirmed zero commits ahead of `main` — old prep branch left over.
- **Drop `git push ado --all`** behavior — handled by the new selective-push workflow in Section 1. Any extra branches that exist on ADO today (other than `dev`, `main`, `public-prep`) will simply stop being updated. Audit with `git ls-remote ado` before flipping.
- **Remove the runtime `eq(Build.SourceBranch, 'refs/heads/main')` conditions** in `function-app.yml` and any other template that has them — compile-time `${{ if }}` blocks already gate by branch, making the runtime check redundant.

### 3d. Out of scope

- **`staging` environment.** Folder `terraform/environments/staging/` exists but is not wired to any pipeline or variable group. Left untouched.
- **CODEOWNERS.** Solo workflow; everything would route to the same owner. Skip.
- **Tag-based release versioning.** Current model uses commit SHA in `DEPLOY_VERSION`; keeping it.
- **Pre-merge GitHub Actions validation** (terraform plan / unit tests). Explicitly rejected — all secrets and TF state access live in ADO; duplicating them into GitHub Secrets or setting up a parallel GH→Azure OIDC identity is more setup than the marginal pre-merge signal is worth. ADO owns all validation.

---

## 4. Migration Sequence

Rollout order, lowest blast radius first:

1. **Create empty `guardianlink-infra-outputs-prod` variable group** in ADO (via REST API or UI). Empty placeholder — real values populated by first prod apply.
2. **Update ADO pipeline YAMLs** (`infra.yml`, `function-app.yml`, per-app pipelines) on a feature branch on GitHub, PR into `dev`. The merge mirrors to ADO dev and exercises the new dev path end-to-end. Validate: dev infra applies, dev app pipelines fire on `refs/heads/dev`, deploys land in dev env.
3. **Once dev path is green**, PR `dev` → `main` to roll the same pipeline changes to prod. The merge exercises the prod path for the first time. Manually approve at the ADO `prod` env gate. Validate: prod infra applies, `guardianlink-infra-outputs-prod` gets populated, prod app pipelines fire on `refs/heads/main`, deploys land in prod env.
4. **Update `mirror-to-ado.yml`** to the selective-push variant last. Until this step, the existing `git push --all` keeps backward compatibility — both `dev` and `main` get mirrored anyway, just sloppily.
5. **Apply GitHub branch protection on `main`** after the full pipeline path is verified.
6. **Delete `public-prep`** on both remotes.

---

## 5. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| First prod run fails because `guardianlink-infra-outputs-prod` is empty | App pipelines fail loudly at the variable-resolution step before any deploy attempts. Re-run after infra populates the VG. |
| `terraform plan` regression caught only after merge | ADO env approval gate means a failed plan never reaches apply. Revert or fix-forward on `main`. |
| Someone pushes directly to ADO | `--force-with-lease` in mirror fails the next mirror push. Investigate before re-mirroring. |
| Mirror workflow runs both dev and main concurrently | Each run pushes a different branch — no conflict at the git layer. ADO pipelines may run concurrently (dev and prod infra in parallel) which is the intent. |
| Pre-existing trigger paths cause "no-op" pipeline runs (e.g., dev branch push that only touched `terraform/environments/prod/`) | Stage `${{ if }}` blocks evaluate false; pipeline runs but produces no stages and exits clean. Wasted seconds, harmless. |

---

## 6. Acceptance Criteria

The branching strategy is considered fully cut over when all of the following hold:

- A direct commit to `dev` (or PR merge into `dev`) triggers the mirror, fires `infra.yml` on the ADO `dev` branch, applies dev TF, populates `guardianlink-infra-outputs`, and triggers app pipelines that deploy to the dev env. Prod env is untouched.
- A PR merge into `main` triggers the mirror, fires `infra.yml` on the ADO `main` branch, requires ADO `prod` env approval, applies prod TF, populates `guardianlink-infra-outputs-prod`, and triggers app pipelines that deploy to the prod env. Dev env is untouched.
- `main` cannot be pushed to directly on GitHub.
- The `public-prep` branch no longer exists on either remote.
- The mirror workflow pushes only the triggering branch — verified by inspecting two consecutive workflow runs (one on dev, one on main).
