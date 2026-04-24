# GuardianLink — Connected Personal Safety Platform

> A realistic-but-fictional Azure cloud platform built for technical interview preparation.
> Target role: Lead Azure DevOps / Cloud Engineer for a connected safety systems company.

## What this project is

GuardianLink is a simulated SaaS product: users wear a BLE device (or run a mobile app) that continuously streams telemetry to the cloud. An ML model watches for crash signatures. When a crash is detected with high confidence, the platform notifies the user's emergency contacts via SMS, email, and push.

This repo is the **cloud backend** for that product. It is deliberately built to mirror the scope of the target JD (see `docs/job-description.md`) without claiming to be a replica of any real company's stack.

## What this project is NOT

- It is not a production system. Do not use it for anything real.
- It is not a replica of Autoliv, Life360, or any specific company's architecture.
- It is not a complete MLOps platform. The ML side is deliberately stubbed.
- It is not attempting to be "compliant" with GDPR or ISO 27001. It is built with those concepts in mind so they can be discussed, not audited.

## Goals of the exercise

In priority order:

1. **Debugging muscle.** Build it, break it, fix it. The break/debug loop (`docs/failure-scenarios.md`) is the primary learning goal.
2. **Architectural fluency.** Be able to defend every design decision in an interview. If you can't explain why a component is there, it shouldn't be there.
3. **Hands-on Terraform with Azure.** Real modules, real state management, real environments.
4. **Observability fluency.** Azure Monitor, Application Insights, Log Analytics — not just "I set up a dashboard," but "I found a bug by correlating traces across three services."
5. **Talk track for the interview.** By the end, you should have 3–4 specific war stories: "I built X, then Y broke, and here's how I found the root cause."

## Repo layout (target state)

```
guardianlink/
├── README.md                   # this file
├── CLAUDE.md                   # instructions for Claude Code
├── docs/
│   ├── architecture.md         # system design + component responsibilities
│   ├── terraform-structure.md  # IaC layout, modules, state, environments
│   ├── failure-scenarios.md    # the break/debug catalog
│   ├── brainstorming-topics.md # open decisions to discuss before building
│   └── job-description.md      # the JD this is prepping for
├── terraform/
│   ├── modules/                # reusable building blocks
│   ├── envs/
│   │   ├── dev/
│   │   └── prod/               # optional — may or may not build
│   └── README.md
├── apps/
│   ├── device-simulator/       # Python; simulates BLE devices
│   ├── telemetry-writer/       # Azure Function
│   ├── crash-classifier/       # Azure Function + ML stub
│   ├── notifier/               # Azure Function
│   └── user-api/               # API fronted by APIM
├── pipelines/
│   └── azure-pipelines.yml     # CI/CD
├── scripts/
│   ├── inject-failure.sh       # used by the break/debug game
│   └── .failure-state/         # gitignored; used by the game
└── .gitignore
```

## Current status

Blueprint phase. Nothing built yet. Start by reading `docs/architecture.md`, then `docs/brainstorming-topics.md`, and have a discussion with Claude Code about the open decisions **before** generating any Terraform.
