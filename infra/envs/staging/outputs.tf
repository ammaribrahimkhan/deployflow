output "resource_group_name" {
  description = "Staging resource group name."
  value       = azurerm_resource_group.this.name
}

output "app_url" {
  description = "Public URL of the staging app."
  value       = module.container_app.url
}

output "container_app_name" {
  description = "Container app name."
  value       = module.container_app.app_name
}

output "log_analytics_workspace_name" {
  description = "Log Analytics workspace name."
  value       = module.monitoring.log_analytics_workspace_name
}

output "app_insights_name" {
  description = "Application Insights name."
  value       = module.monitoring.app_insights_name
}