variable "project" {
  description = "Project name used in resource names."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "location_short" {
  description = "Short region code used in names (for example eus2)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to create the resources in."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace that receives the environment's logs."
  type        = string
}

variable "acr_id" {
  description = "Resource ID of the container registry (for the AcrPull role)."
  type        = string
}

variable "acr_login_server" {
  description = "Login server of the registry, for example myregistry.azurecr.io."
  type        = string
}

variable "image_name" {
  description = "Repository name of the image in the registry."
  type        = string
}

variable "image_tag" {
  description = "Image tag (commit SHA) used for the first deployment."
  type        = string
}

variable "container_port" {
  description = "Port the app listens on."
  type        = number
  default     = 3000
}

variable "cpu" {
  description = "CPU cores per replica."
  type        = number
  default     = 0.25
}

variable "memory" {
  description = "Memory per replica."
  type        = string
  default     = "0.5Gi"
}

variable "min_replicas" {
  description = "Minimum replicas (0 means scale to zero)."
  type        = number
  default     = 0
}

variable "max_replicas" {
  description = "Maximum replicas (cost cap)."
  type        = number
  default     = 2
}