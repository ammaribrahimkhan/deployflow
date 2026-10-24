variable "project" {
  description = "Project name used in resource names."
  type        = string
  default     = "deployflow"
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
  description = "Globally unique registry name (letters and digits only)."
  type        = string
  default     = "acrdeployflowsharedammar03"
}

variable "pipeline_principal_object_id" {
  description = "Object ID of the Azure DevOps service connection's service principal."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.pipeline_principal_object_id))
    error_message = "pipeline_principal_object_id must be a GUID."
  }
}