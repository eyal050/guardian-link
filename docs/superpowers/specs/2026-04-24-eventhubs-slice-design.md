# Event Hubs namespace + telemetry hub — design

**Date:** 2026-04-24
**Stack:** `terraform/guardianlink-dev/`
**Slice scope:** one apply, one area.

## Purpose

Stand up the device-telemetry streaming backbone. This slice creates the Event Hubs namespace and a single hub (`telemetry`) with diagnostic settings wired to the existing Log Analytics workspace. Nothing that consumes from or produces to the hub exists yet — consumer groups, RBAC role assignments, and the IoT Hub route are later slices.

## Context

Current state of `guardianlink-dev`: subscription + RG + budget + Log Analytics + App Insights + Event Grid custom topic (`lifecycle`) + its diagnostic settings.

Architecture commits to a three-way eventing split (`docs/architecture.md`, Decision 7):
- **Event Hubs** for device telemetry — partitioned by `deviceId`, replayable.
- **Service Bus** for crash notifications — at-least-once, DLQ, idempotent notifier.
- **Event Grid** for lifecycle / system events — already built.

This slice delivers the first of those three.

## Resources

New file: `terraform/guardianlink-dev/eventhubs.tf`

### `azurerm_eventhub_namespace`

| Field | Value | Reason |
|---|---|---|
| `name` | `evhns-guardianlink-dev-weu` (composed from `local.name_prefix`) | CAF convention from `terraform-structure.md` |
| `resource_group_name` | `azurerm_resource_group.main.name` | |
| `location` | `azurerm_resource_group.main.location` | |
| `sku` | `"Standard"` | Required for >1 consumer group and ≥2-day retention; Premium is overkill for dev |
| `capacity` | `1` | 1 TU baseline |
| `auto_inflate_enabled` | `true` | |
| `maximum_throughput_units` | `2` | Hard ceiling; keeps cost bounded |
| `public_network_access_enabled` | `true` | Dev, no private endpoints (consistent with Event Grid topic) |
| `local_authentication_enabled` | `false` | Entra/RBAC only; aligns with architecture's managed-identity principle |
| `minimum_tls_version` | `"1.2"` | |
| `tags` | `local.tags` | |
| `provider` | `azurerm.workload` | Mandatory on every workload resource |

Note on zone redundancy: `zone_redundant` is not a settable argument on `azurerm_eventhub_namespace` in azurerm ≥ 4.x — the platform enables it automatically for Standard SKU in AZ-enabled regions (including `westeurope`). Post-apply the namespace reports `zoneRedundant = true` even though no HCL asks for it. This is a platform default, not an override.

### `azurerm_eventhub`

| Field | Value | Reason |
|---|---|---|
| `name` | `"telemetry"` | Namespace-scoped; CAF prefix lives at the namespace |
| `namespace_name` | reference to namespace above | |
| `resource_group_name` | `azurerm_resource_group.main.name` | |
| `partition_count` | `4` | Can grow, cannot shrink on Standard. 4 is textbook default, gives a `deviceId`-hashing story at interview. |
| `message_retention` | `7` | Max included on Standard; supports classifier-replay narrative |

No capture. Rationale: enabling it would require a storage account (premature coupling, violates one-area-per-apply) and would duplicate the telemetry-writer Function's planned blob archive job.

### `azurerm_monitor_diagnostic_setting`

Same shape as the existing Event Grid diagnostic setting (`eventgrid.tf`).

| Field | Value |
|---|---|
| `name` | `diag-evhns-${local.name_prefix}` |
| `target_resource_id` | namespace ID |
| `log_analytics_workspace_id` | `azurerm_log_analytics_workspace.main.id` |
| enabled log categories | `ArchiveLogs`, `OperationalLogs`, `AutoScaleLogs`, `RuntimeAuditLogs` |
| metrics | `AllMetrics` |
| `provider` | `azurerm.workload` |

Category selection rationale:
- `OperationalLogs` — namespace/hub CRUD and config changes.
- `AutoScaleLogs` — records TU inflation events; directly tied to `auto_inflate_enabled = true`.
- `RuntimeAuditLogs` — authentication attempts, relevant given `local_authentication_enabled = false`.
- `ArchiveLogs` — Capture-related; will be empty today (no Capture) but harmless to leave enabled for when it's added.

Categories deliberately omitted: `KafkaCoordinatorLogs`, `KafkaUserErrorLogs` (no Kafka clients in plan), `CustomerManagedKeyUserLogs` (platform-managed keys only), `EventHubVNetConnectionEvent` (no private endpoint).

Diagnostic setting attaches to the **namespace**, not the hub. Hub-level activity is captured under the namespace resource.

## What this slice deliberately excludes

- Consumer groups beyond `$Default` — cheap to add later, no infrastructure coupling.
- RBAC role assignments (`Azure Event Hubs Data Sender` / `Receiver`) — no principals exist to assign them to.
- IoT Hub and its route to this hub — next slice.
- Storage account and Capture — separate slice.
- Service Bus and Event Grid system topics — unrelated slices.
- Private endpoints — dev, cost.
- CMK encryption — platform-managed keys are fine; CMK is a talking point, not a build.

## Variables / locals

No new variables. No `locals.tf` changes. Namespace name composes from the existing `local.name_prefix`; hub name is a literal.

## Post-apply verification

Portal / CLI checks:
- `az eventhubs namespace show -g rg-guardianlink-dev -n evhns-guardianlink-dev-weu` — confirm SKU, auto-inflate, local-auth disabled.
- `az eventhubs eventhub show -g rg-guardianlink-dev --namespace-name evhns-guardianlink-dev-weu -n telemetry` — confirm 4 partitions, 7-day retention.
- Portal → diagnostic settings panel on the namespace → confirm wired to the existing Log Analytics workspace.

Log Analytics check (optional, delayed):
- A few minutes after apply, `AzureDiagnostics | where ResourceType == "NAMESPACES"` should begin returning rows (even if just operational/metric events).

## Risks and notes

- **Sticky partition count.** 4 partitions cannot be decreased. Increasing is possible but mildly disruptive (consumer rebalance, momentary ordering break for existing keys). Accepted.
- **Disabled local auth.** Any future need to produce/consume with SAS (e.g., a local tool outside Azure) will require flipping `local_authentication_enabled` back to `true`. Deliberate trade.
- **No consumers yet.** Namespace will sit idle until IoT Hub route is built. Diagnostic output during that window will be sparse — that's expected, not a regression.
- **Cost.** Standard tier baseline is ~€10/mo for 1 TU + minimal traffic. Auto-inflate cap of 2 TU bounds the worst case. Destroy the stack when not in use per existing guidance.

## Done criteria

- `terraform apply` succeeds from a clean plan.
- Namespace + hub visible in the portal under the child subscription with expected config.
- Diagnostic setting on namespace points at the correct Log Analytics workspace.
- `terraform plan` on a subsequent run reports no drift.
