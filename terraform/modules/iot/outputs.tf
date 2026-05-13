output "iothub_id" {
  value       = azurerm_iothub.main.id
  description = "IoT Hub resource ID."
}

output "iothub_name" {
  value       = azurerm_iothub.main.name
  description = "IoT Hub name."
}

output "iothub_hostname" {
  value       = azurerm_iothub.main.hostname
  description = "IoT Hub hostname for device connections."
}

output "identity_principal_id" {
  value       = azurerm_iothub.main.identity[0].principal_id
  description = "System-assigned managed identity principal ID."
}
