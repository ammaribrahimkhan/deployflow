variable "project" {
  description = "Project name used in resource names."
  type        = string
  default     = "deployflow"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "staging"
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
  description = "Resource group that holds the shared registry and Container Apps environment."
  type        = string
  default     = "rg-deployflow-shared-eus2"
}

variable "container_app_environment_name" {
  description = "Name of the shared Container Apps environment."
  type        = string
  default     = "cae-deployflow-shared-eus2"
}

variable "image_name" {
  description = "Repository name of the image in the registry."
  type        = string
  default     = "deployflow-app"
}

variable "image_tag" {
  description = "Image tag (short commit SHA) to deploy the first time."
  type        = string
}

variable "pipeline_principal_object_id" {
  description = "Object ID of the Azure DevOps service connection's service principal."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.pipeline_principal_object_id))
    error_message = "pipeline_principal_object_id must be a GUID."
  }
}