# Public Repo Preparation — Design Spec

**Date:** 2026-04-29  
**Goal:** Make the GuardianLink repo safe and useful as a public GitHub portfolio project, with clean git history, no sensitive identifiers, a working CI/CD pipeline, and a README that serves both interviewers and other candidates.

---

## 1. Branch Strategy

- Cut `public-prep` from `main`
- All history-rewriting and file changes happen on `public-prep`
- Existing `main` on the remote is untouched until the result is verified
- Final step: force-push `public-prep` → `main`

---

## 2. Git History Rewrites

Two `git filter-repo` passes, in this order:

### Pass 1 — Replace sensitive strings (replace-text)

Create a replacements file and run `git filter-repo --replace-text`. Strings to replace:

| Actual value | Placeholder |
|---|---|
| `<BILLING_SCOPE_ID>` | `<BILLING_SCOPE_ID>` |
| `<BILLING_ACCOUNT_NAME>` | `<BILLING_ACCOUNT_NAME>` |
| `<BILLING_PROFILE_NAME>` | `<BILLING_PROFILE_NAME>` |
| `<INVOICE_SECTION_NAME>` | `<INVOICE_SECTION_NAME>` |
| `<ADO_PROJECT_ID>` | `<ADO_PROJECT_ID>` |

Email addresses (`eyal050@gmail.com`) are left in history — they are the author's public GitHub email and appear in commit metadata; scrubbing them would be disproportionate effort with minimal benefit.

### Pass 2 — Remove `tf-lab-boilerplate/` entirely

```
git filter-repo --path tf-lab-boilerplate --invert-paths
```

Removes the folder from every commit in history. Belt-and-suspenders on top of the replace-text pass since `instructions.txt` contained the billing IDs and the user's full name.

---

## 3. Current File Fixes

Changes to the working tree after history is clean:

### 3a. `terraform/guardianlink-dev/terraform.tfvars` → back to gitignored

- Revert the gitignore exception (`!terraform/guardianlink-dev/terraform.tfvars` line removed from `.gitignore`)
- The file remains locally with real values for the owner's use but is no longer tracked
- `terraform.tfvars.example` already exists with correct placeholders — no changes needed there

### 3b. `terraform/guardianlink-dev/variables.tf` — email defaults

- Change default for `alert_email` from `"eyal050@gmail.com"` → `""`
- Change default for `budget_contact_email` from `"eyal050@gmail.com"` → `""`
- These will be injected by the pipeline via the Variable Group (see §4)

### 3c. `terraform/guardianlink-dev/alerts.tf` — email comment

- Remove the hardcoded email comment on line 4

### 3d. `alerts/README.md`

- Replace `eyal050@gmail.com` with `<your-alert-email>`
- `docs/superpowers/` plan and spec files are left untouched — they are historical design records, not instructional templates

### 3e. `pipelines/infra.yml` — ADO Project ID

- Replace the hardcoded `ADO_PROJECT_ID="<ADO_PROJECT_ID>"` (line 213) with `ADO_PROJECT_ID="$(ADO_PROJECT_ID)"` (sourced from Variable Group)

### 3f. `tf-lab-boilerplate/` — deleted from working tree

Folder is gone from history (Pass 2 above) and deleted from the working tree.

---

## 4. ADO Variable Group Updates

Add the following variables to the existing Variable Group before triggering the pipeline:

| Variable | Value | Secret? |
|---|---|---|
| `TF_VAR_billing_scope_id` | Full MCA scope path | Yes (mark secret) |
| `TF_VAR_alert_email` | `eyal050@gmail.com` | No |
| `TF_VAR_budget_contact_email` | `eyal050@gmail.com` | No |
| `ADO_PROJECT_ID` | `<ADO_PROJECT_ID>` | No |

Update `pipelines/infra.yml` to map `TF_VAR_billing_scope_id` into the Terraform environment wherever `terraform plan` and `terraform apply` are invoked.

For local runs: developer exports `TF_VAR_billing_scope_id` before running `terraform plan`, or keeps a local gitignored `terraform.tfvars` with real values.

---

## 5. README Rewrite

The current README is stale ("Blueprint phase. Nothing built yet.") and has the wrong layout. It needs a full rewrite serving two audiences.

### Audience A — Interviewer landing on the repo

Needs to understand in 60 seconds:
- What GuardianLink is and why it was built
- What has actually been built (not target state)
- The key architectural decisions worth asking about
- Where to look for depth (architecture doc, failure scenarios, observability)

Structure:
1. One-paragraph project summary (what it is, who it's for, what role it targets)
2. "What's built" — current actual state, not aspirational layout
3. Architecture diagram or component list (link to `docs/architecture.md`)
4. "Interesting decisions" — 3–4 bullets pointing to war stories worth discussing in an interview
5. Repo layout (accurate to current state)

### Audience B — Another candidate cloning the repo

Needs a step-by-step setup guide to get the system running themselves:
1. Azure prerequisites (account, MCA billing, create a child subscription)
2. ADO prerequisites (organisation, project, service connection, Variable Group values to populate)
3. Clone and configure (copy `terraform.tfvars.example` → `terraform.tfvars`, fill in values)
4. Run the infra pipeline (or `terraform apply` locally)
5. Run the simulators (`apps/simulator/bootstrap.py` + `sim.py`)
6. Run the consumer (`apps/consumer/bootstrap.py` + `consumer.py`)
7. Verify end-to-end (App Insights traces, Event Hub metrics)

---

## 6. MIT License

Add `LICENSE` file at repo root with standard MIT text, year 2026, copyright holder: Eyal Levi.

---

## 7. Verification Gates

Nothing is considered done until all of these pass:

1. `git log -p | grep -E "<BILLING_ID_PATTERNS>"` returns nothing
2. `git log --all -- tf-lab-boilerplate/` returns nothing
3. `git ls-files terraform/guardianlink-dev/terraform.tfvars` returns nothing
4. ADO infra pipeline `plan` stage passes with VG-injected values
5. `grep -r "eyal050@gmail.com" $(git ls-files)` returns only author-contextual references (commit metadata is exempt), not hardcoded Terraform defaults or instructional text
6. Re-run the full secret-pattern grep from the initial scan against the cleaned repo
7. README renders correctly on GitHub (check headers, code blocks, links)
