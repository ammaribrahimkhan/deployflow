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

variable "retention_in_days" {
  description = "How long logs are kept."
  type        = number
  default     = 30
}

variable "daily_quota_gb" {
  description = "Daily ingestion cap in GB (cost protection)."
  type        = number
  default     = 0.5
}