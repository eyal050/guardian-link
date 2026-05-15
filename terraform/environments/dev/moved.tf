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
