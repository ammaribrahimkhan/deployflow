output "app_name" {
  description = "Name of the container app."
  value       = azurerm_container_app.this.name
}

output "fqdn" {
  description = "Public host name of the app."
  value       = azurerm_container_app.this.ingress[0].fqdn
}

output "url" {
  description = "Public HTTPS URL of the app."
  value       = "https://${azurerm_container_app.this.ingress[0].fqdn}"
}

output "environment_name" {
  description = "Name of the Container Apps environment."
  value       = azurerm_container_app_environment.this.name
}

output "identity_id" {
  description = "Resource ID of the app's managed identity."
  value       = azurerm_user_assigned_identity.app.id
}