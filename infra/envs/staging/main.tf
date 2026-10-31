locals {
  tags = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.project}-${var.environment}-${var.location_short}"
  location = var.location
  tags     = local.tags
}

# The registry, the Container Apps environment, the platform log workspace and the
# action group are created by the "shared" stack, which must be applied first.
data "azurerm_container_registry" "shared" {
  name                = var.acr_name
  resource_group_name = var.shared_resource_group_name
}

data "azurerm_container_app_environment" "shared" {
  name                = var.container_app_environment_name
  resource_group_name = var.shared_resource_group_name
}

data "azurerm_log_analytics_workspace" "platform" {
  name                = var.platform_workspace_name
  resource_group_name = var.shared_resource_group_name
}

data "azurerm_monitor_action_group" "ops" {
  name                = var.action_group_name
  resource_group_name = var.shared_resource_group_name
}

module "monitoring" {
  source = "../../modules/monitoring"

  project             = var.project
  environment         = var.environment
  location            = var.location
  location_short      = var.location_short
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

module "container_app" {
  source = "../../modules/container_app"

  project                      = var.project
  environment                  = var.environment
  location                     = var.location
  location_short               = var.location_short
  resource_group_name          = azurerm_resource_group.this.name
  tags                         = local.tags
  container_app_environment_id = data.azurerm_container_app_environment.shared.id
  acr_id                       = data.azurerm_container_registry.shared.id
  acr_login_server             = data.azurerm_container_registry.shared.login_server
  image_name                   = var.image_name
  image_tag                    = var.image_tag
}

module "alerts" {
  source = "../../modules/alerts"

  environment                = var.environment
  location                   = var.location
  resource_group_name        = azurerm_resource_group.this.name
  tags                       = local.tags
  container_app_id           = module.container_app.app_id
  container_app_name         = module.container_app.app_name
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.platform.id
  app_insights_id            = module.monitoring.app_insights_id
  action_group_id            = data.azurerm_monitor_action_group.ops.id
  availability_url           = "${module.container_app.url}/health"
  enable_availability_test   = var.enable_availability_test
  latency_threshold_ms       = var.latency_alert_threshold_ms
  severity                   = 3
}

# Lets the CD pipeline deploy new revisions of this environment's app.
# Scoped to this resource group only.
resource "azurerm_role_assignment" "pipeline_contributor" {
  scope                            = azurerm_resource_group.this.id
  role_definition_name             = "Contributor"
  principal_id                     = var.pipeline_principal_object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}