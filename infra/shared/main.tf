locals {
  tags = {
    project    = var.project
    scope      = "shared"
    managed_by = "terraform"
  }
}

resource "azurerm_resource_group" "shared" {
  name     = "rg-${var.project}-shared-${var.location_short}"
  location = var.location
  tags     = local.tags
}

# One registry shared by all environments: images are built once and promoted.
resource "azurerm_container_registry" "shared" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags

  # Protects the shared registry from an accidental "terraform destroy".
  lifecycle {
    prevent_destroy = true
  }
}

# Lets the Azure DevOps pipeline push images. Scoped to this resource group only.
resource "azurerm_role_assignment" "pipeline_contributor" {
  scope                            = azurerm_resource_group.shared.id
  role_definition_name             = "Contributor"
  principal_id                     = var.pipeline_principal_object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# Platform logs: everything the Container Apps environment writes goes here.
resource "azurerm_log_analytics_workspace" "platform" {
  name                = "log-${var.project}-shared-${var.location_short}"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 0.5
  tags                = local.tags
}

# The ONE Container Apps environment (free subscriptions allow only one).
# Dev, staging and production run as separate apps inside it.
resource "azurerm_container_app_environment" "shared" {
  name                       = "cae-${var.project}-shared-${var.location_short}"
  location                   = azurerm_resource_group.shared.location
  resource_group_name        = azurerm_resource_group.shared.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.platform.id
  tags                       = local.tags
}