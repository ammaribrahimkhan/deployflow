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

# The registry is created by the "shared" stack, which must be applied first.
data "azurerm_container_registry" "shared" {
  name                = var.acr_name
  resource_group_name = var.acr_resource_group_name
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

  project                    = var.project
  environment                = var.environment
  location                   = var.location
  location_short             = var.location_short
  resource_group_name        = azurerm_resource_group.this.name
  tags                       = local.tags
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
  acr_id                     = data.azurerm_container_registry.shared.id
  acr_login_server           = data.azurerm_container_registry.shared.login_server
  image_name                 = var.image_name
  image_tag                  = var.image_tag
}