output "resource_group_name" {
  description = "Shared resource group name."
  value       = azurerm_resource_group.shared.name
}

output "acr_name" {
  description = "Container registry name."
  value       = azurerm_container_registry.shared.name
}

output "acr_login_server" {
  description = "Container registry login server."
  value       = azurerm_container_registry.shared.login_server
}

output "acr_id" {
  description = "Container registry resource ID."
  value       = azurerm_container_registry.shared.id
}

output "container_app_environment_name" {
  description = "Name of the shared Container Apps environment."
  value       = azurerm_container_app_environment.shared.name
}

output "container_app_environment_id" {
  description = "Resource ID of the shared Container Apps environment."
  value       = azurerm_container_app_environment.shared.id
}

output "log_analytics_workspace_name" {
  description = "Name of the platform Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.platform.name
}