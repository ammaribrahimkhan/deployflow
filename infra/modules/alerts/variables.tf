variable "environment" {
  description = "Environment name (staging, prod)."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group the alert rules are created in."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "container_app_id" {
  description = "Resource ID of the container app to watch."
  type        = string
}

variable "container_app_name" {
  description = "Name of the container app to watch."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Platform Log Analytics workspace that holds the container logs."
  type        = string
}

variable "app_insights_id" {
  description = "Resource ID of this environment's Application Insights."
  type        = string
}

variable "action_group_id" {
  description = "Action group that is notified when an alert fires."
  type        = string
}

variable "availability_url" {
  description = "URL the availability test calls (the /health endpoint)."
  type        = string
}

variable "enable_availability_test" {
  description = "Create the Application Insights availability test and its alert (small monthly cost)."
  type        = bool
  default     = false
}

variable "availability_frequency_seconds" {
  description = "How often the availability test runs (300, 600 or 900 seconds)."
  type        = number
  default     = 900
}

variable "availability_geo_locations" {
  description = "Azure test locations the availability test runs from."
  type        = list(string)
  default     = ["us-va-ash-azr"]
}

variable "severity" {
  description = "Alert severity: 0 critical, 1 error, 2 warning, 3 informational, 4 verbose."
  type        = number
  default     = 2
}

variable "errors_5xx_threshold" {
  description = "Number of 5xx responses in 5 minutes that triggers the alert."
  type        = number
  default     = 5
}

variable "latency_threshold_ms" {
  description = "Average response time (ms) over 15 minutes that triggers the alert."
  type        = number
  default     = 1000
}

variable "restart_threshold" {
  description = "Replica restart count that triggers the alert."
  type        = number
  default     = 3
}

variable "error_rate_threshold_percent" {
  description = "Request error rate (percent) that triggers the log alert."
  type        = number
  default     = 5
}

variable "error_rate_min_requests" {
  description = "Minimum number of requests in the window before the error rate is judged."
  type        = number
  default     = 10
}

variable "unhealthy_events_threshold" {
  description = "Number of crash back-off or image pull problem events in 10 minutes that triggers the unhealthy-revision alert."
  type        = number
  default     = 3
}

variable "probe_failure_threshold" {
  description = "Number of failed health probes in 10 minutes that triggers the unhealthy-revision alert. A few failures are normal while a revision starts or stops, so this is higher."
  type        = number
  default     = 12
}