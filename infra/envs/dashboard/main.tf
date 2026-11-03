data "azurerm_subscription" "current" {}

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

data "azurerm_log_analytics_workspace" "staging" {
  name                = var.staging_workspace_name
  resource_group_name = var.staging_resource_group_name
}

data "azurerm_log_analytics_workspace" "prod" {
  name                = var.prod_workspace_name
  resource_group_name = var.prod_resource_group_name
}

locals {
  tags = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
  }

  app_name = "ca-${var.project}-${var.environment}"

  # Plain settings, no secrets. Empty values are left out.
  env_vars = {
    DASHBOARD_AUTH_MODE       = "easyauth"
    DASHBOARD_ACTIONS_ENABLED = tostring(var.actions_enabled)
    DASHBOARD_ADMINS          = var.admin_emails
    DASHBOARD_CACHE_SECONDS   = "45"
    DEVOPS_ORGANIZATION       = var.devops_organization
    DEVOPS_PROJECT            = var.devops_project
    AZURE_SUBSCRIPTION_ID     = data.azurerm_subscription.current.subscription_id
    AZURE_CLIENT_ID           = azurerm_user_assigned_identity.dashboard.client_id
  }

  env_vars_set = { for name, value in local.env_vars : name => value if value != "" }

  log_workspaces = {
    platform = data.azurerm_log_analytics_workspace.platform.id
    staging  = data.azurerm_log_analytics_workspace.staging.id
    prod     = data.azurerm_log_analytics_workspace.prod.id
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.project}-${var.environment}-${var.location_short}"
  location = var.location
  tags     = local.tags
}

# The identity the dashboard uses to read Azure. No password exists anywhere.
resource "azurerm_user_assigned_identity" "dashboard" {
  name                = "id-${var.project}-${var.environment}-${var.location_short}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

# Pull its own image from the registry.
resource "azurerm_role_assignment" "acr_pull" {
  scope                            = data.azurerm_container_registry.shared.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.dashboard.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# Read-only access to Azure resources (apps, revisions, alerts). It cannot change anything.
resource "azurerm_role_assignment" "subscription_reader" {
  scope                            = data.azurerm_subscription.current.id
  role_definition_name             = "Reader"
  principal_id                     = azurerm_user_assigned_identity.dashboard.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# Read-only access to the logs it queries (and only to those workspaces).
resource "azurerm_role_assignment" "logs_reader" {
  for_each = local.log_workspaces

  scope                            = each.value
  role_definition_name             = "Log Analytics Reader"
  principal_id                     = azurerm_user_assigned_identity.dashboard.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# Azure AD needs a moment to spread new role assignments.
resource "time_sleep" "wait_for_roles" {
  depends_on      = [azurerm_role_assignment.acr_pull]
  create_duration = "60s"
}

# Lets the dashboard pipeline deploy new images of this app. Scoped to this resource group only.
resource "azurerm_role_assignment" "pipeline_contributor" {
  scope                            = azurerm_resource_group.this.id
  role_definition_name             = "Contributor"
  principal_id                     = var.pipeline_principal_object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_container_app" "dashboard" {
  name                         = local.app_name
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = data.azurerm_container_app_environment.shared.id
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.dashboard.id]
  }

  registry {
    server   = data.azurerm_container_registry.shared.login_server
    identity = azurerm_user_assigned_identity.dashboard.id
  }

  ingress {
    external_enabled           = true
    target_port                = 3000
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 0
    max_replicas = 1

    container {
      name   = "dashboard"
      image  = "${data.azurerm_container_registry.shared.login_server}/${var.image_name}:${var.image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      dynamic "env" {
        for_each = local.env_vars_set

        content {
          name  = env.key
          value = env.value
        }
      }

      liveness_probe {
        transport               = "HTTP"
        port                    = 3000
        path                    = "/healthz"
        initial_delay           = 10
        interval_seconds        = 30
        timeout                 = 3
        failure_count_threshold = 3
      }

      readiness_probe {
        transport               = "HTTP"
        port                    = 3000
        path                    = "/healthz"
        interval_seconds        = 10
        timeout                 = 3
        failure_count_threshold = 3
        success_count_threshold = 1
      }
    }
  }

  # The dashboard pipeline deploys new images; Terraform must not undo them.
  lifecycle {
    ignore_changes = [
      template[0].container[0].image,
    ]
  }

  depends_on = [time_sleep.wait_for_roles]
}