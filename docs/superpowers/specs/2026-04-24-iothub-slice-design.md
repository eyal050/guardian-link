# IoT Hub + route to telemetry Event Hub — design

**Date:** 2026-04-24
**Stack:** `terraform/guardianlink-dev/`
**Slice scope:** one apply, one area.

## Purpose

Stand up the device-ingestion layer. IoT Hub terminates device connections and routes every device-to-cloud message to the existing `telemetry` Event Hub via managed identity (no SAS connection string on the route). After this slice, the ingestion pipeline runs end-to-end: `device → IoT Hub → Event Hub`. Producers and consumers of that hub still don't exist — the simulator, telemetry-writer Function, and classifier come later.

## Context

Current stack (commit `f772620`): subscription + RG + budget + Log Analytics + App Insights + Event Grid lifecycle topic + Event Hubs namespace with `telemetry` hub (4 partitions, 7-day retention, Entra-only auth).

Architecture commits (`docs/architecture.md`):
- Decision #7: "IoT Hub routes all device messages to Event Hubs only." Discrimination of crash-suspect events happens downstream at the classifier's confidence threshold, not at ingest.
- "Managed identities everywhere possible" — the IoT Hub → Event Hubs route uses IoT Hub's system-assigned identity with the `Azure Event Hubs Data Sender` role, not a shared access signature.
- "X.509 preferred, SAS for the simulator" — device-facing auth model. This slice keeps SAS enabled on IoT Hub so the future simulator can connect; X.509 is deferred to when the simulator lands.

## Resources

New file: `terraform/guardianlink-dev/iot.tf`

### 1. `azurerm_iothub.main`

| Field | Value | Reason |
|---|---|---|
| `name` | `iot-${local.name_prefix}` → `iot-guardianlink-dev-weu` | CAF |
| `resource_group_name` | `azurerm_resource_group.main.name` | |
| `location` | `var.primary_location` | |
| `sku.name` | `"F1"` | Free tier; 8K msgs/day; feature-complete (twin, C2D, X.509, routing, MI) |
| `sku.capacity` | `1` | F1 allows only 1 |
| `local_authentication_enabled` | `true` | SAS enabled so the future simulator can connect; X.509 work deferred |
| `public_network_access_enabled` | `true` | dev, no private endpoints |
| `event_hub_partition_count` | `2` | Built-in endpoint partitions; sticky. Fallback-only traffic, pick minimum. |
| `identity.type` | `"SystemAssigned"` | System identity used by the route to authenticate to Event Hubs |
| `tags` | `local.tags` | |
| `provider` | `azurerm.workload` | |

No `cloud_to_device` block — Azure defaults are fine; no C2D in use yet.

No custom `shared_access_policy` blocks — the provider/Azure creates the built-in policies (`iothubowner`, `service`, `device`, `registryRead`, `registryReadWrite`). Those suffice for the planned simulator's `device`-scoped SAS use and future service access.

No DPS (Device Provisioning Service) in this slice. Devices will be registered manually via the IoT Hub identity registry when the simulator arrives.

Importantly: **no inline `endpoint` or `route` blocks on this resource.** They are expressed as separate resources (below) so the endpoint can `depends_on` the role assignment, breaking the otherwise circular dependency on the IoT Hub's principal ID.

### 2. `azurerm_role_assignment.iot_to_eh_sender`

```hcl
resource "azurerm_role_assignment" "iot_to_eh_sender" {
  provider             = azurerm.workload
  scope                = azurerm_eventhub.telemetry.id
  role_definition_name = "Azure Event Hubs Data Sender"
  principal_id         = azurerm_iothub.main.identity[0].principal_id
}
```

Scoped to the **hub** (`azurerm_eventhub.telemetry.id`), not the namespace. Least privilege: IoT Hub's identity gets `Send` on exactly one hub.

### 3. `azurerm_iothub_endpoint_eventhub.telemetry`

```hcl
resource "azurerm_iothub_endpoint_eventhub" "telemetry" {
  provider            = azurerm.workload
  name                = "telemetry-eh"
  resource_group_name = azurerm_resource_group.main.name
  iothub_id           = azurerm_iothub.main.id
  authentication_type = "identityBased"
  endpoint_uri        = "sb://${azurerm_eventhub_namespace.main.name}.servicebus.windows.net"
  entity_path         = azurerm_eventhub.telemetry.name

  depends_on = [azurerm_role_assignment.iot_to_eh_sender]
}
```

`authentication_type = "identityBased"` + implicit SystemAssigned identity (no `identity_id` → uses the IoT Hub's system identity). `endpoint_uri` uses the Service Bus namespace FQDN; `entity_path` is the hub name.

The `depends_on` is load-bearing. IoT Hub validates endpoint credentials at creation time; without the role assignment present first, validation fails with a permission error.

### 4. `azurerm_iothub_route.all_to_telemetry`

```hcl
resource "azurerm_iothub_route" "all_to_telemetry" {
  provider            = azurerm.workload
  resource_group_name = azurerm_resource_group.main.name
  iothub_name         = azurerm_iothub.main.name
  name                = "route-all-to-telemetry-eh"
  source              = "DeviceMessages"
  condition           = "true"
  endpoint_names      = [azurerm_iothub_endpoint_eventhub.telemetry.name]
  enabled             = true
}
```

`condition = "true"` matches every D2C message. Matches architecture decision #7 exactly. Classifier downstream discriminates on event properties (e.g., `eventType=crash_suspect`), not at ingest.

No explicit `fallback_route`. Azure's implicit fallback (to the built-in `events` endpoint) stays enabled. Harmless: the `true` route matches everything first, fallback fires only on no-match.

### 5. `azurerm_monitor_diagnostic_setting.iothub`

Same shape as the Event Hubs diag setting (`eventhubs.tf`).

| Field | Value |
|---|---|
| `name` | `diag-iot-${local.name_prefix}` |
| `target_resource_id` | `azurerm_iothub.main.id` |
| `log_analytics_workspace_id` | `azurerm_log_analytics_workspace.main.id` |
| enabled log categories | `Connections`, `DeviceTelemetry`, `Routes`, `DeviceIdentityOperations` |
| metrics | `AllMetrics` |
| `provider` | `azurerm.workload` |

Category selection rationale:
- `Connections` — device connect/disconnect + auth outcomes.
- `DeviceTelemetry` — D2C message visibility.
- `Routes` — **critical for this slice**: route delivery attempts + outcomes. This is where the MI-based route surfaces failures (e.g., missing RBAC, endpoint unreachable).
- `DeviceIdentityOperations` — registry changes; forward-useful for when devices arrive.

Categories omitted (YAGNI): Kafka, C2D/D2C twin operations, twin queries, jobs, direct methods, distributed tracing, configurations, file upload, device streams. Add on the slice that introduces each.

## What this slice deliberately excludes

- Simulator / any device client.
- X.509 device identities, device CA, or DPS.
- Custom SAS policies (the built-in ones suffice).
- Consumer groups on the `telemetry` Event Hub (still no consumers).
- Telemetry-writer, classifier, or any Function.
- Key Vault references.
- Private endpoints.

## Variables / locals

No new variables. No `locals.tf` changes. Hub name composes from existing `local.name_prefix`.

## Post-apply verification

Switch to the child subscription first (`az account set --subscription WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER`).

1. IoT Hub config:
   ```
   az iot hub show -g rg-guardianlink-dev -n iot-guardianlink-dev-weu \
     --query "{sku:sku.name, capacity:sku.capacity, disableLocalAuth:properties.disableLocalAuth, publicAccess:properties.publicNetworkAccess, partitions:properties.eventHubEndpoints.events.partitionCount, identity:identity.type, principalId:identity.principalId}" -o table
   ```
   Expected: `Sku = F1`, `Capacity = 1`, `DisableLocalAuth = False` (= SAS enabled), `PublicAccess = Enabled`, `Partitions = 2`, `Identity = SystemAssigned`, principal ID populated.

2. Role assignment on the hub:
   ```
   EH_ID=$(az eventhubs eventhub show -g rg-guardianlink-dev --namespace-name evhns-guardianlink-dev-weu -n telemetry --query id -o tsv)
   az role assignment list --scope "$EH_ID" --query "[].{role:roleDefinitionName, principalType:principalType, principalId:principalId}" -o table
   ```
   Expected: one row with `role = Azure Event Hubs Data Sender`, `principalType = ServicePrincipal`, principal ID matching the IoT Hub's.

3. IoT Hub endpoint + route:
   ```
   az iot hub routing-endpoint list --hub-name iot-guardianlink-dev-weu -g rg-guardianlink-dev --query "eventHubs[].{name:name, authType:authenticationType, uri:endpointUri, path:entityPath}" -o table
   az iot hub route list --hub-name iot-guardianlink-dev-weu -g rg-guardianlink-dev -o table
   ```
   Expected: one endpoint `telemetry-eh` with `authType = identityBased`; one route `route-all-to-telemetry-eh` with `source = DeviceMessages`, `condition = true`, targeting `telemetry-eh`, enabled.

4. Diagnostic setting:
   ```
   IOT_ID=$(az iot hub show -g rg-guardianlink-dev -n iot-guardianlink-dev-weu --query id -o tsv)
   az monitor diagnostic-settings list --resource "$IOT_ID" \
     --query "[].{name:name, workspace:workspaceId, logs:logs[?enabled].category, metrics:metrics[?enabled].category}" -o json
   ```
   Expected: `name = diag-iot-guardianlink-dev-weu`, workspace points at `log-guardianlink-dev-weu`, logs contain exactly the four enabled categories, metrics contain `AllMetrics`.

## Risks and notes

- **F1 quota silently 429s.** If dev traffic exceeds 8K msgs/day the hub rejects without a loud failure. `DeviceTelemetry` / `Connections` logs will surface it if we're paying attention. Not a concern for simulator-scale traffic.
- **SAS enabled.** Rotatable device keys exist and must be handled carefully when the simulator arrives. Architecture accepts this tradeoff; flip `local_authentication_enabled = false` when X.509 story is ready.
- **One free IoT Hub per subscription limit.** We're in the child subscription and no other IoT Hub exists, so fine. Future stacks must consider this.
- **Terraform destroy-recreate on SKU change.** F1 → S1 transitions in Azure require a new hub (or Azure-side in-place upgrade, which azurerm may not model cleanly). Accept as future cost if we ever want S1 for load testing.
- **Route condition = true catches everything.** If a future slice introduces crash-suspect-specific routing into a separate destination, this route remains dominant. Plan the interaction then.

## Done criteria

- `terraform apply` succeeds from a clean plan; 5 resources added (IoT Hub, role assignment, endpoint, route, diagnostic setting).
- Re-plan reports no drift.
- All four post-apply `az` checks return the expected output.
- Spec + plan + `iot.tf` committed together.
