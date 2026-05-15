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
