output "resource_group_name" {
  description = "Dashboard resource group name."
  value       = azurerm_resource_group.this.name
}

output "app_name" {
  description = "Dashboard container app name."
  value       = azurerm_container_app.dashboard.name
}

output "app_url" {
  description = "Public URL of the dashboard (sign-in required)."
  value       = "https://${azurerm_container_app.dashboard.ingress[0].fqdn}"
}

output "identity_name" {
  description = "Name of the dashboard's managed identity."
  value       = azurerm_user_assigned_identity.dashboard.name
}

output "identity_principal_id" {
  description = "Object ID of the dashboard's managed identity."
  value       = azurerm_user_assigned_identity.dashboard.principal_id
}