variable "project" {
  description = "Project name used in resource names."
  type        = string
  default     = "deployflow"
}

variable "environment" {
  description = "Name used in resource names."
  type        = string
  default     = "dashboard"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "eastus2"
}

variable "location_short" {
  description = "Short region code used in names."
  type        = string
  default     = "eus2"
}

variable "acr_name" {
  description = "Name of the shared container registry."
  type        = string
  default     = "acrdeployflowsharedammar03"
}

variable "shared_resource_group_name" {
  description = "Resource group of the shared registry, Container Apps environment and platform log workspace."
  type        = string
  default     = "rg-deployflow-shared-eus2"
}

variable "container_app_environment_name" {
  description = "Name of the shared Container Apps environment."
  type        = string
  default     = "cae-deployflow-shared-eus2"
}

variable "platform_workspace_name" {
  description = "Platform Log Analytics workspace (container logs)."
  type        = string
  default     = "log-deployflow-shared-eus2"
}

variable "staging_workspace_name" {
  description = "Staging Log Analytics workspace (deployment events, availability)."
  type        = string
  default     = "log-deployflow-staging-eus2"
}

variable "staging_resource_group_name" {
  description = "Resource group of the staging workspace."
  type        = string
  default     = "rg-deployflow-staging-eus2"
}

variable "prod_workspace_name" {
  description = "Production Log Analytics workspace (deployment events, availability)."
  type        = string
  default     = "log-deployflow-prod-eus2"
}

variable "prod_resource_group_name" {
  description = "Resource group of the production workspace."
  type        = string
  default     = "rg-deployflow-prod-eus2"
}

variable "image_name" {
  description = "Repository name of the dashboard image."
  type        = string
  default     = "deployflow-dashboard"
}

variable "image_tag" {
  description = "Image tag (short commit SHA) used for the first deployment."
  type        = string
}

variable "devops_organization" {
  description = "Azure DevOps organization name."
  type        = string
  default     = "deployflow-ammar03"
}

variable "devops_project" {
  description = "Azure DevOps project name."
  type        = string
  default     = "DeployFlow"
}

variable "admin_emails" {
  description = "Signed-in users who are administrators, comma separated, exactly as /api/me shows them."
  type        = string
  default     = ""
}

variable "actions_enabled" {
  description = "Allow administrators to queue a deployment or a rollback from the dashboard."
  type        = bool
  default     = false
}

variable "pipeline_principal_object_id" {
  description = "Object ID of the Azure DevOps service connection's service principal."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.pipeline_principal_object_id))
    error_message = "pipeline_principal_object_id must be a GUID."
  }
}