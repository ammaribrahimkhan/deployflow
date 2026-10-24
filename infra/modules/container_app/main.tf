# Identity the app uses to pull images. No passwords anywhere.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${var.project}-${var.environment}-${var.location_short}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Least privilege: the identity may only PULL images from this one registry.
resource "azurerm_role_assignment" "acr_pull" {
  scope                            = var.acr_id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.app.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# Azure AD needs a moment to spread a new role assignment.
resource "time_sleep" "wait_for_role_assignment" {
  depends_on      = [azurerm_role_assignment.acr_pull]
  create_duration = "60s"
}

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${var.project}-${var.environment}-${var.location_short}"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  log_analytics_workspace_id = var.log_analytics_workspace_id
  tags                       = var.tags
}

resource "azurerm_container_app" "this" {
  name                         = "ca-${var.project}-${var.environment}"
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.this.id

  # "Multiple" lets two revisions run side by side (needed for traffic splitting in Milestone 6).
  revision_mode = "Multiple"
  tags          = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = var.acr_login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  ingress {
    external_enabled           = true
    target_port                = var.container_port
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = "app"
      image  = "${var.acr_login_server}/${var.image_name}:${var.image_tag}"
      cpu    = var.cpu
      memory = var.memory

      env {
        name  = "APP_ENV"
        value = var.environment
      }

      liveness_probe {
        transport               = "HTTP"
        port                    = var.container_port
        path                    = "/health"
        initial_delay           = 10
        interval_seconds        = 30
        timeout                 = 3
        failure_count_threshold = 3
      }

      readiness_probe {
        transport               = "HTTP"
        port                    = var.container_port
        path                    = "/health"
        interval_seconds        = 10
        timeout                 = 3
        failure_count_threshold = 3
        success_count_threshold = 1
      }
    }
  }

  # Terraform creates the app. The pipeline deploys new images later,
  # so Terraform must not undo those deployments.
  lifecycle {
    ignore_changes = [
      template[0].container[0].image,
    ]
  }

  depends_on = [time_sleep.wait_for_role_assignment]
}