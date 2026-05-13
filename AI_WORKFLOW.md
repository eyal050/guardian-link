# AI-Augmented Development Workflow

## How this repo was built

GuardianLink was built using an AI-augmented engineering workflow. The architectural decisions, tradeoff analysis, component design, and operational runbooks are mine. Claude Code (and Codex) executed implementation under my direction — generating Terraform modules, Function App code, and pipeline YAML from specifications I wrote, then iterating based on my review.

This is a deliberate methodology, not a shortcut. The goal was to practice the engineering judgment that matters in a senior platform role — making the right call on IoT Hub vs raw Event Hubs, three-way eventing split semantics, idempotency design for the notifier — while offloading mechanical implementation so I could cover more architectural ground faster.

**What I drove:**
- Every decision in `docs/architecture.md` — including the rationale for rejecting alternatives
- The failure injection catalog (`docs/failure-scenarios.md`) and the diagnosis methodology
- The observability design: which KQL queries to write, which alerts matter, which metrics proxy for business health
- All infrastructure topology: subscription model, managed identity grants, RBAC scope, network rules

**What AI executed:**
- Terraform resource definitions from my component specs
- Function App boilerplate wired to my trigger and output binding specs
- Azure DevOps pipeline YAML scaffolding
- First drafts of KQL alert rules (I reviewed and revised each one)

---

## AI tool instructions

The sections below are instructions for AI tools (Claude Code, Codex) working in this repo. They are included here so the methodology is transparent.

### Top-line behavior

1. **Challenge decisions.** Default is NOT to agree. If the user asks for something that conflicts with the architecture doc, push back with reasoning.

2. **Ask before building.** Before generating Terraform, function code, or pipeline YAML, confirm:
   - Which component are we building now?
   - Have the relevant brainstorming-topics been resolved?
   - What's the smallest piece we can deploy and verify?

3. **Build incrementally.** One small module → deploy → verify → next. Refuse requests for "the whole thing" and propose a first slice.

4. **Teach by making the user drive.** Explain every non-obvious choice briefly. Prompt follow-up questions if the user doesn't ask.

5. **Fail loudly on missing context.** If asked to work on a component not in `docs/architecture.md`, stop and ask where it fits.

6. **Commit + push after every working slice.** Stage files explicitly (never `git add -A`). Commit with a message explaining the *why*. Do not commit WIP.

### The failure-injection game

See `docs/failure-scenarios.md` for the full protocol.

- **"Break failure #N"** — inject the fault, record in `scripts/.failure-state/current.md`, do not reveal what changed.
- **"Break a random one"** — pick from the catalog (avoid recently-done per `history.md`), inject, record.
- **"What was the fault?" / "Reveal"** — read `current.md`, help post-mortem.
- **"Revert"** — restore to known-good state.

Rules:
- Never reveal the active failure in the chat response.
- Never leave breadcrumbs in committed code.
- Injected fault must be plausible — something that could happen in a real system.
- After diagnosis: short post-mortem, what alert or test would have caught it faster.
- `scripts/.failure-state/` must be in `.gitignore`.

### What AI must NOT do

- Generate more than one module per user request without explicit approval
- Invent resources not in `docs/architecture.md`
- Silently resolve open decisions from `docs/brainstorming-topics.md`
- Use Bicep — Terraform only
- Write secrets to code or tfvars — Key Vault references only
- Commit `.failure-state/` to git
- Flatter the user

### First session bootstrap

1. Read `README.md`, `docs/architecture.md`, `docs/failure-scenarios.md`, and this file.
2. Check `scripts/.failure-state/current.md` — active failure? If yes, remind the user (without revealing which one).
3. Ask what we're working on today.
4. Do not generate code until scope is clear.
