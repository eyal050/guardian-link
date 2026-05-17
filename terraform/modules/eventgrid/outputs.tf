output "lifecycle_topic_id" {
  value       = azurerm_eventgrid_topic.lifecycle.id
  description = "Lifecycle topic resource ID."
}
output "lifecycle_topic_name" {
  value       = azurerm_eventgrid_topic.lifecycle.name
  description = "Lifecycle topic name."
}
