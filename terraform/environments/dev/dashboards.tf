# Application Insights Workbook visualizing the telemetry pipeline.
#
# Queries are sourced from dashboards/queries/*.kql so they can be
# reviewed as standalone Kusto. The workbook structure itself lives
# here as HCL and is serialized via jsonencode -- no separate
# workbook.json artifact in the repo, no JSON-string-escaping
# headaches.
#
# The {TimeRange} tokens inside the .kql files are workbook parameter
# syntax (substituted by Azure at render time based on the user's
# selection), NOT Terraform interpolation. Treat them as literal
# strings.

locals {
  workbook_queries = {
    throughput               = file("${path.module}/../../../dashboards/queries/throughput.kql")
    event_type_distribution  = file("${path.module}/../../../dashboards/queries/event_type_distribution.kql")
    producer_consumer_totals = file("${path.module}/../../../dashboards/queries/producer_consumer_totals.kql")
    partition_distribution   = file("${path.module}/../../../dashboards/queries/partition_distribution.kql")
  }

  workbook_data = jsonencode({
    version = "Notebook/1.0"
    items = [
      # 1. Markdown header
      {
        type = 1
        name = "header"
        content = {
          json = "## GuardianLink — telemetry pipeline\n\nThroughput, event-type mix, end-to-end parity, and partition distribution for the device-ingest path. Use the time-range picker below to zoom in or out; all panels react."
        }
      },
      # 2. Time-range parameter
      {
        type = 9
        name = "time-range"
        content = {
          version = "KqlParameterItem/1.0"
          parameters = [
            {
              id         = "11111111-1111-1111-1111-111111111111"
              version    = "KqlParameterItem/1.0"
              name       = "TimeRange"
              type       = 4
              isRequired = true
              value = {
                durationMs = 86400000
              }
              typeSettings = {
                selectableValues = [
                  { durationMs = 1800000 },   # 30 minutes
                  { durationMs = 3600000 },   # 1 hour
                  { durationMs = 14400000 },  # 4 hours
                  { durationMs = 86400000 },  # 24 hours
                  { durationMs = 604800000 }, # 7 days
                ]
              }
            }
          ]
        }
      },
      # 3. Throughput timechart
      {
        type = 3
        name = "throughput"
        content = {
          version       = "KqlItem/1.0"
          query         = local.workbook_queries.throughput
          size          = 0
          title         = "Throughput (messages/min)"
          timeContext   = { durationMs = 86400000 }
          queryType     = 0
          resourceType  = "microsoft.insights/components"
          visualization = "timechart"
        }
      },
      # 4. Event-type pie
      {
        type = 3
        name = "event-type-distribution"
        content = {
          version       = "KqlItem/1.0"
          query         = local.workbook_queries.event_type_distribution
          size          = 0
          title         = "Distribution by event_type (sent)"
          timeContext   = { durationMs = 86400000 }
          queryType     = 0
          resourceType  = "microsoft.insights/components"
          visualization = "piechart"
        }
      },
      # 5. Producer/Consumer tiles
      {
        type = 3
        name = "producer-consumer-totals"
        content = {
          version       = "KqlItem/1.0"
          query         = local.workbook_queries.producer_consumer_totals
          size          = 0
          title         = "Producer vs Consumer (totals)"
          timeContext   = { durationMs = 86400000 }
          queryType     = 0
          resourceType  = "microsoft.insights/components"
          visualization = "tiles"
        }
      },
      # 6. Partition bar chart
      {
        type = 3
        name = "partition-distribution"
        content = {
          version       = "KqlItem/1.0"
          query         = local.workbook_queries.partition_distribution
          size          = 0
          title         = "Messages received by partition"
          timeContext   = { durationMs = 86400000 }
          queryType     = 0
          resourceType  = "microsoft.insights/components"
          visualization = "barchart"
        }
      },
    ]
    "$schema" = "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"
  })
}

resource "azurerm_application_insights_workbook" "telemetry" {
  provider = azurerm.workload

  # Azure requires Workbook resource names to be a GUID. Hardcoded to
  # keep state stable; random_uuid() would track in state and a
  # destroy-recreate cycle would surface as scary diff churn.
  name                = "5b2d4f70-1a2c-4e8f-9c1b-7e3a8d6f9a01"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.primary_location

  display_name = "GuardianLink — telemetry pipeline"
  category     = "workbook"
  # Provider validation requires source_id to be all lowercase, but
  # Azure returns the ID with mixed case (Microsoft.Insights/...).
  source_id = lower(azurerm_application_insights.main.id)
  data_json = local.workbook_data

  tags = local.tags
}
