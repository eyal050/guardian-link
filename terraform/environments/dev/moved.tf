# State migration: maps every legacy root-level address to its new module.X.Y form.
# Populated incrementally as each component is extracted into a module.
# moved blocks are evaluated at plan time; no apply needed for the move itself.

# observability
moved {
  from = azurerm_log_analytics_workspace.main
  to   = module.observability.azurerm_log_analytics_workspace.main
}
moved {
  from = azurerm_application_insights.main
  to   = module.observability.azurerm_application_insights.main
}

# storage
moved {
  from = random_string.storage_suffix
  to   = module.storage.random_string.storage_suffix
}
moved {
  from = azurerm_storage_account.main
  to   = module.storage.azurerm_storage_account.main
}
moved {
  from = azurerm_storage_container.eh_checkpoints
  to   = module.storage.azurerm_storage_container.eh_checkpoints
}
moved {
  from = azurerm_monitor_diagnostic_setting.storage_blob
  to   = module.storage.azurerm_monitor_diagnostic_setting.storage_blob
}
moved {
  from = random_string.raw_archive_suffix
  to   = module.storage.random_string.raw_archive_suffix
}
moved {
  from = azurerm_storage_account.raw_archive
  to   = module.storage.azurerm_storage_account.raw_archive
}
moved {
  from = azurerm_storage_container.telemetry_raw
  to   = module.storage.azurerm_storage_container.telemetry_raw
}
moved {
  from = azurerm_monitor_diagnostic_setting.raw_archive_blob
  to   = module.storage.azurerm_monitor_diagnostic_setting.raw_archive_blob
}

# keyvault
moved {
  from = azurerm_key_vault.main
  to   = module.keyvault.azurerm_key_vault.main
}
moved {
  from = azurerm_role_assignment.kv_operator_secrets_officer
  to   = module.keyvault.azurerm_role_assignment.kv_operator_secrets_officer
}
moved {
  from = azurerm_key_vault_secret.appi_connection_string
  to   = module.keyvault.azurerm_key_vault_secret.appi_connection_string
}

# cosmos
moved {
  from = azurerm_cosmosdb_account.main
  to   = module.cosmos.azurerm_cosmosdb_account.main
}
moved {
  from = azurerm_cosmosdb_sql_database.main
  to   = module.cosmos.azurerm_cosmosdb_sql_database.main
}
moved {
  from = azurerm_cosmosdb_sql_container.telemetry
  to   = module.cosmos.azurerm_cosmosdb_sql_container.telemetry
}
moved {
  from = azurerm_cosmosdb_sql_container.notifications
  to   = module.cosmos.azurerm_cosmosdb_sql_container.notifications
}
moved {
  from = azurerm_monitor_diagnostic_setting.cosmos
  to   = module.cosmos.azurerm_monitor_diagnostic_setting.cosmos
}

# eventhubs
moved {
  from = azurerm_eventhub_namespace.main
  to   = module.eventhubs.azurerm_eventhub_namespace.main
}
moved {
  from = azurerm_eventhub.telemetry
  to   = module.eventhubs.azurerm_eventhub.telemetry
}
moved {
  from = azurerm_monitor_diagnostic_setting.eventhub_namespace
  to   = module.eventhubs.azurerm_monitor_diagnostic_setting.eventhub_namespace
}
moved {
  from = azurerm_eventhub_consumer_group.inspector
  to   = module.eventhubs.azurerm_eventhub_consumer_group.inspector
}

# servicebus
moved {
  from = azurerm_servicebus_namespace.main
  to   = module.servicebus.azurerm_servicebus_namespace.main
}
moved {
  from = azurerm_servicebus_queue.crash_confirmed
  to   = module.servicebus.azurerm_servicebus_queue.crash_confirmed
}
moved {
  from = azurerm_eventhub_consumer_group.crash_classifier
  to   = module.servicebus.azurerm_eventhub_consumer_group.crash_classifier
}
moved {
  from = azurerm_monitor_diagnostic_setting.servicebus_namespace
  to   = module.servicebus.azurerm_monitor_diagnostic_setting.servicebus_namespace
}
