locals {
  tags = {
    project    = var.project
    scope      = "shared"
    managed_by = "terraform"
  }
}

data "azurerm_subscription" "current" {}

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

# Who gets told when an alert fires.
resource "azurerm_monitor_action_group" "ops" {
  name                = "ag-${var.project}-ops"
  resource_group_name = azurerm_resource_group.shared.name
  short_name          = "dfops"
  tags                = local.tags

  email_receiver {
    name                    = "ops-email"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

# Infrastructure issues: Azure service incidents in our region.
resource "azurerm_monitor_activity_log_alert" "service_health" {
  name                = "alert-${var.project}-service-health"
  resource_group_name = azurerm_resource_group.shared.name
  location            = "global"
  scopes              = [data.azurerm_subscription.current.id]
  description         = "An Azure service incident affects East US 2."
  tags                = local.tags

  criteria {
    category = "ServiceHealth"

    service_health {
      events    = ["Incident"]
      locations = ["East US 2"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}