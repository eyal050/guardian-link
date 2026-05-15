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

# iot
moved {
  from = azurerm_iothub.main
  to   = module.iot.azurerm_iothub.main
}
moved {
  from = azurerm_role_assignment.iot_to_eh_sender
  to   = module.iot.azurerm_role_assignment.iot_to_eh_sender
}
moved {
  from = azurerm_iothub_endpoint_eventhub.telemetry
  to   = module.iot.azurerm_iothub_endpoint_eventhub.telemetry
}
moved {
  from = azurerm_iothub_route.all_to_telemetry
  to   = module.iot.azurerm_iothub_route.all_to_telemetry
}
moved {
  from = azurerm_monitor_diagnostic_setting.iothub
  to   = module.iot.azurerm_monitor_diagnostic_setting.iothub
}

# eventgrid
moved {
  from = azurerm_eventgrid_topic.lifecycle
  to   = module.eventgrid.azurerm_eventgrid_topic.lifecycle
}
moved {
  from = azurerm_monitor_diagnostic_setting.eventgrid_lifecycle
  to   = module.eventgrid.azurerm_monitor_diagnostic_setting.eventgrid_lifecycle
}

# postgres
moved {
  from = random_password.postgres_admin
  to   = module.postgres.random_password.postgres_admin
}
moved {
  from = random_password.postgres_notifier
  to   = module.postgres.random_password.postgres_notifier
}
moved {
  from = azurerm_key_vault_secret.postgres_admin_password
  to   = module.postgres.azurerm_key_vault_secret.postgres_admin_password
}
moved {
  from = azurerm_key_vault_secret.postgres_notifier_password
  to   = module.postgres.azurerm_key_vault_secret.postgres_notifier_password
}
moved {
  from = azurerm_postgresql_flexible_server.main
  to   = module.postgres.azurerm_postgresql_flexible_server.main
}
moved {
  from = azurerm_postgresql_flexible_server_database.guardianlink
  to   = module.postgres.azurerm_postgresql_flexible_server_database.guardianlink
}
moved {
  from = azurerm_postgresql_flexible_server_firewall_rule.azure_services
  to   = module.postgres.azurerm_postgresql_flexible_server_firewall_rule.azure_services
}
moved {
  from = azurerm_postgresql_flexible_server_firewall_rule.dev_all
  to   = module.postgres.azurerm_postgresql_flexible_server_firewall_rule.dev_all
}

# ml-stub
moved {
  from = azurerm_container_registry.main
  to   = module.ml_stub.azurerm_container_registry.main
}
moved {
  from = azurerm_container_app_environment.main
  to   = module.ml_stub.azurerm_container_app_environment.main
}
moved {
  from = azurerm_container_app.ml_stub
  to   = module.ml_stub.azurerm_container_app.ml_stub
}

# functions (telemetry-writer)
moved {
  from = azurerm_eventhub_consumer_group.telemetry_writer
  to   = module.functions.azurerm_eventhub_consumer_group.telemetry_writer
}
moved {
  from = azurerm_service_plan.functions
  to   = module.functions.azurerm_service_plan.functions
}
moved {
  from = azurerm_linux_function_app.telemetry_writer
  to   = module.functions.azurerm_linux_function_app.telemetry_writer
}
moved {
  from = azurerm_role_assignment.func_to_eh_receiver
  to   = module.functions.azurerm_role_assignment.func_to_eh_receiver
}
moved {
  from = random_uuid.cosmos_writer_role_assignment
  to   = module.functions.random_uuid.cosmos_writer_role_assignment
}
moved {
  from = azurerm_cosmosdb_sql_role_assignment.func_to_cosmos_writer
  to   = module.functions.azurerm_cosmosdb_sql_role_assignment.func_to_cosmos_writer
}
moved {
  from = azurerm_role_assignment.func_to_blob_archive
  to   = module.functions.azurerm_role_assignment.func_to_blob_archive
}
moved {
  from = azurerm_monitor_diagnostic_setting.functions_writer
  to   = module.functions.azurerm_monitor_diagnostic_setting.functions_writer
}

# crash-classifier
moved {
  from = azurerm_linux_function_app.crash_classifier
  to   = module.crash_classifier.azurerm_linux_function_app.crash_classifier
}
moved {
  from = azurerm_role_assignment.classifier_to_eh_receiver
  to   = module.crash_classifier.azurerm_role_assignment.classifier_to_eh_receiver
}
moved {
  from = random_uuid.cosmos_classifier_role_assignment
  to   = module.crash_classifier.random_uuid.cosmos_classifier_role_assignment
}
moved {
  from = azurerm_cosmosdb_sql_role_assignment.classifier_to_cosmos_reader
  to   = module.crash_classifier.azurerm_cosmosdb_sql_role_assignment.classifier_to_cosmos_reader
}
moved {
  from = azurerm_role_assignment.classifier_to_sb_sender
  to   = module.crash_classifier.azurerm_role_assignment.classifier_to_sb_sender
}
moved {
  from = azurerm_monitor_diagnostic_setting.functions_classifier
  to   = module.crash_classifier.azurerm_monitor_diagnostic_setting.functions_classifier
}

# metrics
moved {
  from = azurerm_eventhub_consumer_group.metrics
  to   = module.metrics.azurerm_eventhub_consumer_group.metrics
}
moved {
  from = azurerm_linux_function_app.metrics
  to   = module.metrics.azurerm_linux_function_app.metrics
}
moved {
  from = azurerm_role_assignment.metrics_to_eh_receiver
  to   = module.metrics.azurerm_role_assignment.metrics_to_eh_receiver
}
moved {
  from = azurerm_monitor_diagnostic_setting.functions_metrics
  to   = module.metrics.azurerm_monitor_diagnostic_setting.functions_metrics
}

# notifier
moved {
  from = azurerm_communication_service.main
  to   = module.notifier.azurerm_communication_service.main
}
moved {
  from = azurerm_email_communication_service.main
  to   = module.notifier.azurerm_email_communication_service.main
}
moved {
  from = azurerm_email_communication_service_domain.azure_managed
  to   = module.notifier.azurerm_email_communication_service_domain.azure_managed
}
moved {
  from = azurerm_key_vault_secret.acs_connection_string
  to   = module.notifier.azurerm_key_vault_secret.acs_connection_string
}
moved {
  from = azurerm_linux_function_app.notifier
  to   = module.notifier.azurerm_linux_function_app.notifier
}
moved {
  from = azurerm_role_assignment.notifier_to_sb_receiver
  to   = module.notifier.azurerm_role_assignment.notifier_to_sb_receiver
}
moved {
  from = random_uuid.cosmos_notifier_role_assignment
  to   = module.notifier.random_uuid.cosmos_notifier_role_assignment
}
moved {
  from = azurerm_cosmosdb_sql_role_assignment.notifier_to_cosmos_contributor
  to   = module.notifier.azurerm_cosmosdb_sql_role_assignment.notifier_to_cosmos_contributor
}
moved {
  from = azurerm_role_assignment.notifier_to_kv_secrets_user
  to   = module.notifier.azurerm_role_assignment.notifier_to_kv_secrets_user
}
moved {
  from = azurerm_monitor_diagnostic_setting.functions_notifier
  to   = module.notifier.azurerm_monitor_diagnostic_setting.functions_notifier
}

# budget
moved {
  from = azurerm_consumption_budget_subscription.main
  to   = module.budget.azurerm_consumption_budget_subscription.main
}

# alerts
moved {
  from = azurerm_monitor_action_group.email
  to   = module.alerts.azurerm_monitor_action_group.email
}
moved {
  from = azurerm_monitor_scheduled_query_rules_alert_v2.no_telemetry
  to   = module.alerts.azurerm_monitor_scheduled_query_rules_alert_v2.no_telemetry
}
moved {
  from = azurerm_monitor_scheduled_query_rules_alert_v2.crash_spike
  to   = module.alerts.azurerm_monitor_scheduled_query_rules_alert_v2.crash_spike
}
moved {
  from = azurerm_monitor_scheduled_query_rules_alert_v2.no_iot_connections
  to   = module.alerts.azurerm_monitor_scheduled_query_rules_alert_v2.no_iot_connections
}

# dashboards
moved {
  from = azurerm_application_insights_workbook.telemetry
  to   = module.dashboards.azurerm_application_insights_workbook.telemetry
}
