# Azure Monitor scheduled-query alerts on the producer side.
#
# Three rules, one action group with a single email receiver (var.alert_email).
# The KQL for each rule is sourced from alerts/queries/*.kql so the queries
# can be reviewed as standalone Kusto.
#
# Two rules scope to App Insights (`message_sent` rows from the
# simulator), one scopes to LAW (`AzureDiagnostics` -> IoT Hub
# Connections category). Mixing scope types in a single resource is
# not supported by azurerm_monitor_scheduled_query_rules_alert_v2 --
# that's why we have three resources, not one with three criteria
# blocks.
#
# v2 criteria-block quirks (worth re-reading before editing):
#   1. Threshold lives in HCL (operator / metric_measure_column /
#      threshold), NOT in the KQL. The KQL just exposes the count
#      column. Changing the KQL alone will NOT change firing behavior.
#   2. failing_periods is mandatory. 1 of 1 = no dampening.
#   3. query_time_range_override should match window_duration or the
#      query lookback silently shrinks to the eval cadence.

locals {
  alert_queries = {
    no_telemetry       = file("${path.module}/../../../alerts/queries/no_telemetry.kql")
    crash_spike        = file("${path.module}/../../../alerts/queries/crash_spike.kql")
    no_iot_connections = file("${path.module}/../../../alerts/queries/no_iot_connections.kql")
  }
}

resource "azurerm_monitor_action_group" "email" {
  provider = azurerm.workload

  name                = "ag-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "glink-dev" # 12-char max, shows in email subject

  email_receiver {
    name          = "eyal-primary"
    email_address = var.alert_email
  }

  tags = local.tags
}

# ---------- Rule 1: no telemetry from the simulator ----------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "no_telemetry" {
  provider = azurerm.workload

  name                = "alert-no-telemetry-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.primary_location

  scopes                  = [azurerm_application_insights.main.id]
  severity                = 3
  evaluation_frequency    = "PT5M"
  window_duration         = "PT10M"
  description             = "No message_sent events in the last 10 minutes from the simulator."
  enabled                 = true
  auto_mitigation_enabled = true

  criteria {
    query                   = local.alert_queries.no_telemetry
    time_aggregation_method = "Total"
    metric_measure_column   = "sent"
    threshold               = 0
    operator                = "Equal"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  query_time_range_override = "PT10M"

  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }

  tags = local.tags
}

# ---------- Rule 2: crash_suspect rate spike ----------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "crash_spike" {
  provider = azurerm.workload

  name                = "alert-crash-spike-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.primary_location

  scopes                  = [azurerm_application_insights.main.id]
  severity                = 2
  evaluation_frequency    = "PT5M"
  window_duration         = "PT10M"
  description             = "More than 10 crash_suspect events in the last 10 minutes (baseline ~5)."
  enabled                 = true
  auto_mitigation_enabled = true

  criteria {
    query                   = local.alert_queries.crash_spike
    time_aggregation_method = "Total"
    metric_measure_column   = "crashes"
    threshold               = 10
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  query_time_range_override = "PT10M"

  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }

  tags = local.tags
}

# ---------- Rule 3: no IoT Hub successful Connections ----------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "no_iot_connections" {
  provider = azurerm.workload

  name                = "alert-no-iot-connections-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.primary_location

  scopes                  = [azurerm_log_analytics_workspace.main.id]
  severity                = 2
  evaluation_frequency    = "PT15M"
  window_duration         = "PT30M"
  description             = "No successful IoT Hub Connections rows in AzureDiagnostics over the last 30 minutes."
  enabled                 = true
  auto_mitigation_enabled = true

  criteria {
    query                   = local.alert_queries.no_iot_connections
    time_aggregation_method = "Total"
    metric_measure_column   = "connects"
    threshold               = 0
    operator                = "Equal"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  query_time_range_override = "PT30M"

  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }

  tags = local.tags
}
