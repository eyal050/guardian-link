output "action_group_id" {
  value       = azurerm_monitor_action_group.email.id
  description = "Action group resource ID -- forward-compat for additional alert wiring."
}
