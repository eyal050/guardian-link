# IoT Hub slice — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an F1 IoT Hub to `guardianlink-dev` with a system-assigned identity and a routing rule that sends every device-to-cloud message to the existing `telemetry` Event Hub via managed-identity auth (no SAS connection string on the route).

**Architecture:** One new file `terraform/guardianlink-dev/iot.tf` containing five resources: `azurerm_iothub`, `azurerm_role_assignment`, `azurerm_iothub_endpoint_eventhub`, `azurerm_iothub_route`, `azurerm_monitor_diagnostic_setting`. Endpoint + route are expressed as separate resources (not inline blocks on `azurerm_iothub`) so the endpoint can `depends_on` the role assignment — IoT Hub validates endpoint credentials at create-time and would otherwise hit a chicken-and-egg on the principal ID. All resources use `provider = azurerm.workload`. Spec: `docs/superpowers/specs/2026-04-24-iothub-slice-design.md`.

**Tech Stack:** Terraform (`azurerm` ~> 4.69), Azure CLI for post-apply verification. No application code.

**Stack-specific mechanics** (same as the Event Hubs slice):
- `./run.sh <cmd>` wraps `terraform init` with backend config and exports `ARM_SUBSCRIPTION_ID`. Use it for every `plan` / `apply` / `validate` command.
- Every workload resource MUST set `provider = azurerm.workload` — forgetting that line lands the resource in the parent subscription.
- The state backend is external and persistent; `terraform destroy` on this stack is safe between sessions.

**Testing approach:** No unit-test framework for Terraform. Each task validates by `terraform fmt`, `./run.sh validate`, and `./run.sh plan` producing the expected resource additions. Post-apply verification uses `az` CLI against the child subscription.

**Known Azure / azurerm gotchas to watch for during plan/apply:**
- F1 tier allows exactly 1 free IoT Hub per Azure subscription. The `guardianlink-dev` child subscription has none yet, so this is fine — but the error if it did exist would be "Cannot create more than one free IoT hub per subscription."
- Inline `endpoint {}` / `route {}` blocks on `azurerm_iothub` and separate `azurerm_iothub_endpoint_*` / `azurerm_iothub_route` resources cannot coexist. This plan uses the separate-resource form exclusively.
- `authentication_type = "identityBased"` requires the IoT Hub's system identity to already hold `Azure Event Hubs Data Sender` on the target hub *before* the endpoint is created. The `depends_on` in Task 4 is load-bearing.

---

## File Structure

- **Create:** `terraform/guardianlink-dev/iot.tf` — all five resources for this slice.
- **Modify:** none.
- **Already exists and referenced:** `rg.tf` (`azurerm_resource_group.main`), `observability.tf` (`azurerm_log_analytics_workspace.main`), `eventhubs.tf` (`azurerm_eventhub_namespace.main`, `azurerm_eventhub.telemetry`), `locals.tf` (`local.name_prefix`, `local.tags`), `variables.tf` (`var.primary_location`).

---

## Task 1: Create iot.tf with the IoT Hub resource

**Files:**
- Create: `terraform/guardianlink-dev/iot.tf`

- [ ] **Step 1: Create `iot.tf` containing only the IoT Hub**

Write this exact content:

```hcl
# IoT Hub terminates device connections (MQTT/AMQP over TLS) and routes
# every device-to-cloud message to the telemetry Event Hub via its own
# system-assigned managed identity.
#
# F1 (Free) SKU: feature-complete (twin, C2D, X.509, routing, MI) but
# capped at 8000 msgs/day and exactly one instance per Azure subscription.
# Plenty for simulator-scale dev; interview talking point for prod sizing.
#
# local_authentication_enabled = true: SAS device tokens remain accepted
# so the future simulator can connect with a device connection string.
# X.509-only hardening is deferred to the simulator slice when a device
# CA / cert story is in scope.
#
# event_hub_partition_count applies to the built-in 'events' endpoint.
# Since the route below sends everything to the external telemetry hub,
# the built-in endpoint only receives unmatched-fallback traffic. Set
# to the F1 minimum.
resource "azurerm_iothub" "main" {
  provider = azurerm.workload

  name                = "iot-${local.name_prefix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name

  sku {
    name     = "F1"
    capacity = 1
  }

  local_authentication_enabled  = true
  public_network_access_enabled = true
  event_hub_partition_count     = 2

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}
```

- [ ] **Step 2: Format and validate**

Run from `terraform/guardianlink-dev/`:
```bash
terraform fmt
./run.sh validate
```
Expected: `fmt` silent (or normalizes whitespace); `validate` prints `Success! The configuration is valid` (pre-existing `metric` deprecation warnings on earlier diag settings are unrelated and fine).

- [ ] **Step 3: Plan and inspect**

```bash
./run.sh plan
```
Expected: plan shows exactly **1 resource to add** (`azurerm_iothub.main`), 0 to change, 0 to destroy. Confirm the printed fields:
- `name = "iot-guardianlink-dev-weu"`
- `sku { name = "F1", capacity = 1 }`
- `local_authentication_enabled = true`
- `public_network_access_enabled = true`
- `event_hub_partition_count = 2`
- `identity { type = "SystemAssigned" }`

If any field is missing or different, fix the HCL and re-plan before moving on. In particular, if azurerm rejects `event_hub_partition_count` or `local_authentication_enabled` with an "argument not supported" error, the provider version drifted from the pinned `~> 4.69.0`; stop and investigate rather than working around it.

---

## Task 2: Add the role assignment

**Files:**
- Modify: `terraform/guardianlink-dev/iot.tf` (append)

- [ ] **Step 1: Append the role assignment**

Append to `terraform/guardianlink-dev/iot.tf`:

```hcl
# IoT Hub's system identity needs Send permission on the telemetry hub
# so the identity-based route below can publish messages without SAS.
# Scoped to the hub (not the namespace) for least privilege.
resource "azurerm_role_assignment" "iot_to_eh_sender" {
  provider = azurerm.workload

  scope                = azurerm_eventhub.telemetry.id
  role_definition_name = "Azure Event Hubs Data Sender"
  principal_id         = azurerm_iothub.main.identity[0].principal_id
}
```

- [ ] **Step 2: Format and validate**

```bash
terraform fmt
./run.sh validate
```
Expected: both clean.

- [ ] **Step 3: Plan and inspect**

```bash
./run.sh plan
```
Expected: plan shows exactly **2 resources to add** (IoT Hub + role assignment), 0 to change, 0 to destroy. On the role assignment:
- `scope` references `azurerm_eventhub.telemetry` (the `telemetry` hub ID)
- `role_definition_name = "Azure Event Hubs Data Sender"`
- `principal_id = (known after apply)` — resolves once the IoT Hub's identity is created

---

## Task 3: Add the Event Hub endpoint

**Files:**
- Modify: `terraform/guardianlink-dev/iot.tf` (append)

- [ ] **Step 1: Append the endpoint resource**

Append to `terraform/guardianlink-dev/iot.tf`:

```hcl
# Identity-based routing endpoint pointing at the telemetry hub.
# 'identityBased' + no explicit identity_id means IoT Hub authenticates
# with its own system-assigned identity. Requires Data Sender role on
# the target hub to already exist at create time — hence depends_on.
resource "azurerm_iothub_endpoint_eventhub" "telemetry" {
  provider = azurerm.workload

  name                = "telemetry-eh"
  resource_group_name = azurerm_resource_group.main.name
  iothub_id           = azurerm_iothub.main.id

  authentication_type = "identityBased"
  endpoint_uri        = "sb://${azurerm_eventhub_namespace.main.name}.servicebus.windows.net"
  entity_path         = azurerm_eventhub.telemetry.name

  depends_on = [azurerm_role_assignment.iot_to_eh_sender]
}
```

- [ ] **Step 2: Format and validate**

```bash
terraform fmt
./run.sh validate
```
Expected: both clean.

- [ ] **Step 3: Plan and inspect**

```bash
./run.sh plan
```
Expected: plan shows exactly **3 resources to add**, 0 to change, 0 to destroy. On the endpoint:
- `name = "telemetry-eh"`
- `authentication_type = "identityBased"`
- `endpoint_uri = "sb://evhns-guardianlink-dev-weu.servicebus.windows.net"`
- `entity_path = "telemetry"`
- No `connection_string` field set

---

## Task 4: Add the route

**Files:**
- Modify: `terraform/guardianlink-dev/iot.tf` (append)

- [ ] **Step 1: Append the route resource**

Append to `terraform/guardianlink-dev/iot.tf`:

```hcl
# Route every device-to-cloud message to the telemetry endpoint.
# source=DeviceMessages + condition=true matches all D2C traffic;
# crash-suspect discrimination happens downstream at the classifier,
# not at ingest (docs/architecture.md decision #7).
#
# No explicit fallback_route: Azure's implicit fallback (to the
# built-in 'events' endpoint) stays enabled. With condition=true
# matching everything first, the fallback is moot in practice.
resource "azurerm_iothub_route" "all_to_telemetry" {
  provider = azurerm.workload

  resource_group_name = azurerm_resource_group.main.name
  iothub_name         = azurerm_iothub.main.name

  name           = "route-all-to-telemetry-eh"
  source         = "DeviceMessages"
  condition      = "true"
  endpoint_names = [azurerm_iothub_endpoint_eventhub.telemetry.name]
  enabled        = true
}
```

- [ ] **Step 2: Format and validate**

```bash
terraform fmt
./run.sh validate
```
Expected: both clean.

- [ ] **Step 3: Plan and inspect**

```bash
./run.sh plan
```
Expected: plan shows exactly **4 resources to add**, 0 to change, 0 to destroy. On the route:
- `name = "route-all-to-telemetry-eh"`
- `source = "DeviceMessages"`
- `condition = "true"`
- `endpoint_names = ["telemetry-eh"]`
- `enabled = true`

---

## Task 5: Add the diagnostic setting

**Files:**
- Modify: `terraform/guardianlink-dev/iot.tf` (append)

- [ ] **Step 1: Append the diagnostic setting**

Append to `terraform/guardianlink-dev/iot.tf`:

```hcl
# Send IoT Hub logs + metrics to the shared Log Analytics workspace.
# Categories selected for what this slice actually exercises:
# - Connections             : device connect/disconnect + auth outcomes
# - DeviceTelemetry         : D2C message flow into the hub
# - Routes                  : route delivery attempts + failures.
#                             Critical for this slice - any breakage in
#                             the MI-based endpoint surfaces here.
# - DeviceIdentityOperations: registry changes (useful when devices arrive)
# Kafka / twin / jobs / direct methods categories omitted - not used yet.
resource "azurerm_monitor_diagnostic_setting" "iothub" {
  provider = azurerm.workload

  name                       = "diag-iot-${local.name_prefix}"
  target_resource_id         = azurerm_iothub.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "Connections"
  }

  enabled_log {
    category = "DeviceTelemetry"
  }

  enabled_log {
    category = "Routes"
  }

  enabled_log {
    category = "DeviceIdentityOperations"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
```

- [ ] **Step 2: Format and validate**

```bash
terraform fmt
./run.sh validate
```
Expected: both clean.

- [ ] **Step 3: Plan and inspect**

```bash
./run.sh plan
```
Expected: plan shows exactly **5 resources to add**, 0 to change, 0 to destroy. On the diagnostic setting:
- `name = "diag-iot-guardianlink-dev-weu"`
- `target_resource_id = (known after apply)` referencing the IoT Hub
- `log_analytics_workspace_id` referencing the existing `azurerm_log_analytics_workspace.main`
- Four `enabled_log` blocks (Connections, DeviceTelemetry, Routes, DeviceIdentityOperations)
- One `metric { category = "AllMetrics", enabled = true }` block

If the plan tries to modify or destroy anything other than adding these five resources, STOP — something drifted. Investigate before applying.

---

## Task 6: Apply

**Files:** none.

- [ ] **Step 1: Apply**

```bash
./run.sh apply -auto-approve
```

Expected: `Apply complete! Resources: 5 added, 0 changed, 0 destroyed.` Total apply time typically 2–5 minutes — IoT Hub creation itself is the slow part (often 60–90s), then the endpoint/route/role finish in seconds.

If apply fails on the endpoint with a 403 / permission error, it means the role assignment had not yet propagated when IoT Hub tried to validate the endpoint. Azure RBAC can take 30–60s to propagate after a role is granted. Re-running `./run.sh apply` once typically resolves it. This is an Azure quirk, not a plan bug — do not restructure the code.

- [ ] **Step 2: Confirm no drift**

```bash
./run.sh plan
```
Expected: `No changes. Your infrastructure matches the configuration.` If drift is reported, record exactly what changed and stop — investigate before proceeding.

---

## Task 7: Post-apply verification via Azure CLI

**Files:** none.

Switch to the child subscription first. All `az` commands below must run against the `guardianlink-dev` subscription; the parent sub will 404 misleadingly.

```bash
az account set --subscription "WORKLOAD_SUBSCRIPTION_ID_PLACEHOLDER"
az account show --query "{name:name, id:id}" -o table   # sanity check -> Name: guardianlink-dev
```

- [ ] **Step 1: Verify IoT Hub core config + identity**

```bash
az iot hub show -g "rg-guardianlink-dev" -n "iot-guardianlink-dev-weu" \
  --query "{sku:sku.name, capacity:sku.capacity, disableLocalAuth:properties.disableLocalAuth, publicAccess:properties.publicNetworkAccess, partitions:properties.eventHubEndpoints.events.partitionCount, identity:identity.type, principalId:identity.principalId}" \
  -o table
```

Expected:
- `Sku = F1`
- `Capacity = 1`
- `DisableLocalAuth = False` (SAS accepted — the inverse of Terraform's `local_authentication_enabled = true`)
- `PublicAccess = Enabled`
- `Partitions = 2`
- `Identity = SystemAssigned`
- `PrincipalId` populated (a GUID)

Capture the principal ID for the next step:
```bash
IOT_PRINCIPAL=$(az iot hub show -g "rg-guardianlink-dev" -n "iot-guardianlink-dev-weu" --query "identity.principalId" -o tsv)
echo "IoT Hub principal: $IOT_PRINCIPAL"
```

- [ ] **Step 2: Verify role assignment on the telemetry hub**

```bash
EH_ID=$(az eventhubs eventhub show -g "rg-guardianlink-dev" --namespace-name "evhns-guardianlink-dev-weu" -n "telemetry" --query id -o tsv)
az role assignment list --scope "$EH_ID" \
  --query "[].{role:roleDefinitionName, principalType:principalType, principalId:principalId}" \
  -o table
```

Expected: exactly one assignment with
- `role = Azure Event Hubs Data Sender`
- `principalType = ServicePrincipal`
- `principalId` matches `$IOT_PRINCIPAL` from Step 1

If role assignment inheritance from the namespace or subscription shows additional rows, that's fine — focus on the hub-scoped one.

- [ ] **Step 3: Verify the routing endpoint**

```bash
az iot hub routing-endpoint list --hub-name "iot-guardianlink-dev-weu" -g "rg-guardianlink-dev" \
  --query "eventHubs[].{name:name, authType:authenticationType, uri:endpointUri, path:entityPath, resourceGroup:resourceGroup, subscription:subscriptionId}" \
  -o table
```

Expected: one row with
- `Name = telemetry-eh`
- `AuthType = identityBased`
- `Uri = sb://evhns-guardianlink-dev-weu.servicebus.windows.net`
- `Path = telemetry`

- [ ] **Step 4: Verify the route**

```bash
az iot hub route list --hub-name "iot-guardianlink-dev-weu" -g "rg-guardianlink-dev" \
  --query "[].{name:name, source:source, condition:condition, endpoints:endpointNames, enabled:isEnabled}" \
  -o table
```

Expected: one row with
- `Name = route-all-to-telemetry-eh`
- `Source = DeviceMessages`
- `Condition = true`
- `Endpoints = ['telemetry-eh']`
- `Enabled = True`

- [ ] **Step 5: Verify the diagnostic setting**

```bash
IOT_ID=$(az iot hub show -g "rg-guardianlink-dev" -n "iot-guardianlink-dev-weu" --query id -o tsv)
az monitor diagnostic-settings list --resource "$IOT_ID" \
  --query "[].{name:name, workspace:workspaceId, logs:logs[?enabled].category, metrics:metrics[?enabled].category}" \
  -o json
```

Expected JSON with one entry:
- `name = "diag-iot-guardianlink-dev-weu"`
- `workspace` ends with `/providers/Microsoft.OperationalInsights/workspaces/log-guardianlink-dev-weu`
- `logs` contains exactly: `Connections`, `DeviceTelemetry`, `Routes`, `DeviceIdentityOperations` (order may differ)
- `metrics` contains `AllMetrics`

---

## Task 8: Commit spec + plan + TF together

**Files:**
- Stage: `docs/superpowers/specs/2026-04-24-iothub-slice-design.md`
- Stage: `docs/superpowers/plans/2026-04-24-iothub-slice.md`
- Stage: `terraform/guardianlink-dev/iot.tf`

Per project preference, the design spec and plan stay uncommitted during the slice and land in the same commit as the Terraform.

- [ ] **Step 1: Stage the exact files (no `git add -A`)**

```bash
git add \
  docs/superpowers/specs/2026-04-24-iothub-slice-design.md \
  docs/superpowers/plans/2026-04-24-iothub-slice.md \
  terraform/guardianlink-dev/iot.tf
```

- [ ] **Step 2: Confirm staged set matches expectation**

```bash
git status --short
```
Expected: exactly three `A ` (staged-added) lines for the files above; nothing else staged. If `terraform.tfvars` or any `.failure-state/` path appears, `git restore --staged <file>` before continuing.

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
add IoT Hub + identity-based route to the telemetry hub

iot-guardianlink-dev-weu: F1 (free) tier, SystemAssigned identity, SAS
device auth kept enabled for the future simulator. One endpoint
(telemetry-eh) and one route (route-all-to-telemetry-eh, source
DeviceMessages, condition true) push every D2C message to the existing
'telemetry' Event Hub via managed identity. IoT Hub's principal gets
Azure Event Hubs Data Sender scoped to the hub (not the namespace) for
least privilege.

Endpoint + route are separate resources (not inline blocks on
azurerm_iothub) so the endpoint can depends_on the role assignment --
IoT Hub validates endpoint credentials at create-time.

Diagnostic settings route Connections, DeviceTelemetry, Routes,
DeviceIdentityOperations + AllMetrics to the existing Log Analytics
workspace.

Out of scope: simulator, X.509 device identities, DPS, consumer groups
on the Event Hub, telemetry-writer / classifier Functions.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify working tree is clean**

```bash
git status --short
```
Expected: empty (or only untracked files intentionally left out, e.g. `terraform.tfvars`).

---

## Done criteria (from spec)

- `terraform apply` succeeded; 5 resources added (Task 6).
- Re-plan reports no drift (Task 6 Step 2).
- All four verification checks in Task 7 return expected output.
- Spec + plan + `iot.tf` committed together (Task 8).

## Update persistent state after completion

After Task 8 succeeds, update the project-state memory at
`/home/eyal/.claude/projects/-home-eyal-repos-guardian-link/memory/project-state.md`:
- Add IoT Hub + endpoint + route + role assignment + diagnostic setting to the "applied as of" list.
- Bump the commit SHA reference.
- Trim the "next slice candidates" list: IoT Hub is no longer a candidate; add "simulator (device client)" as the natural follow-on if not already implied.
