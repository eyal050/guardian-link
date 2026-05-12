# GuardianLink — Azure IoT Safety Platform

A reference implementation of a production-grade Azure backend for a connected personal safety platform.
Demonstrates end-to-end patterns for device telemetry ingestion, event-driven processing, observability, and zero-credential CI/CD on Azure.

## Architecture at a glance

![Architecture diagram placeholder — see docs/architecture.md](docs/architecture.png)

**Telemetry path:** Device → IoT Hub → Event Hubs → Telemetry Writer (Function) → Cosmos DB
**Alert path:** Crash classifier (Function) → Service Bus → Notifier (Function) → SendGrid + Postgres history
**Routing:** Event Grid for cross-system fan-out
**Operations:** App Insights + Log Analytics + KQL-based Azure Monitor alerts + workbook dashboard

Full design and decision log: [`docs/architecture.md`](docs/architecture.md)

## Key design decisions

These are the decisions worth discussing in detail. Each represents a deliberate tradeoff, not a default.

**IoT Hub + Event Hubs (not just Event Hubs).** Per-device identity, per-device throttling, and the D2C routing model are essential for a connected-device fleet.
Event Hubs alone gives you throughput but loses device-level governance.

**Managed identity everywhere.** `local_authentication_enabled = false` on Event Hubs.
Every resource authenticates via Entra ID.
Zero connection strings in app settings or pipeline variables.
CI/CD uses OIDC-federated workload identity — no stored secrets in Azure DevOps.

**Separate Function Apps per workload.** The crash classifier and the notifier have different SLOs and different blast radius.
Co-locating them would couple their fate.
Each Function App is independently scaled, deployed, and observed.

**PaaS over AKS for this workload profile.** The application's scaling and operational profile didn't justify the operational overhead of AKS.
This is a deliberate choice with a documented decision record, not a knowledge gap.
A parallel AKS-based variant is on the roadmap to demonstrate the alternative.

**Failure-injection-driven validation.** [`docs/failure-scenarios.md`](docs/failure-scenarios.md) catalogs realistic production failures (dependency outages, partial degradation, misconfigurations).
Each is reproducible. Diagnosis is performed using only Azure Monitor and App Insights, with post-mortems written against each scenario.

## Stack

| Layer | Technology |
|---|---|
| Infrastructure as Code | Terraform (≥ 1.7), remote state in Azure Storage |
| CI/CD | Azure DevOps pipelines with OIDC service connection |
| Device ingestion | Azure IoT Hub |
| Event streaming | Azure Event Hubs (4 partitions, RBAC-only) |
| Compute | Azure Functions (Python v2 model) |
| State | Cosmos DB (device/event), PostgreSQL Flexible Server (notification history) |
| Messaging | Service Bus + Event Grid |
| Secrets | Azure Key Vault (accessed via managed identity) |
| Observability | App Insights + Log Analytics + Azure Monitor Workbook |
| Alerting | Azure Monitor scheduled-query rules (KQL) |
| Notifications | SendGrid |

## Repository layout

```
.
├── docs/                            architecture, decisions, failure scenarios
├── terraform/
│   └── guardianlink-dev/            dev environment (staging/prod variants on roadmap)
├── apps/                            Python applications
│   ├── simulator/                   device simulators
│   ├── consumer/                    Event Hub inspector
│   ├── telemetry-writer/            Function: ingestion → Cosmos
│   ├── crash-classifier/            Function: classification + ML stub
│   ├── notifier/                    Function: alert delivery
│   └── metrics/                     Function: aggregation
├── pipelines/                       Azure DevOps YAML pipelines (one per workload)
├── alerts/                          KQL queries for Azure Monitor alert rules
└── dashboards/                      Azure Monitor workbook (JSON)
```

## Roadmap

- AKS-based variant of the telemetry consumer path (Key Vault CSI driver, HPA, network policies)
- Staging + production environment separation with promotion pipeline
- Integration test suite covering the simulator → IoT Hub → Event Hub → Cosmos path
- Real ML model replacing the classifier stub

## Setup

Detailed setup instructions, including Azure DevOps variable groups, OIDC service connection configuration, and local Terraform execution, are in [`SETUP.md`](SETUP.md).

## License

MIT — see [`LICENSE`](LICENSE).
