locals {
  # Share of failed requests (status 500 or higher), ignoring the /health endpoint.
  error_rate_query = <<-QUERY
    ContainerAppConsoleLogs_CL
    | where ContainerAppName_s == '${var.container_app_name}'
    | where Log_s startswith '{'
    | extend j = parse_json(Log_s)
    | where isnotnull(j.status)
    | extend status = toint(j.status), path = tostring(j.path)
    | where path !startswith '/health'
    | summarize total = count(), failed = countif(status >= 500)
    | extend errorPercent = iff(total == 0, 0.0, 100.0 * failed / total)
    | where total >= ${var.error_rate_min_requests} and errorPercent > ${var.error_rate_threshold_percent}
  QUERY

  # Platform events that mean a revision is unhealthy.
  unhealthy_query = <<-QUERY
    ContainerAppSystemLogs_CL
    | where ContainerAppName_s == '${var.container_app_name}'
    | where Reason_s in ('ProbeFailed', 'ContainerBackOff', 'ImagePullBackOff', 'ErrImagePull') or Log_s has_any ('probe failed', 'back-off', 'failed to pull image')
    | summarize events = count()
    | where events >= ${var.unhealthy_events_threshold}
  QUERY
}

# ---------------------------------------------------------------- metric alerts (fast, cheap)

resource "azurerm_monitor_metric_alert" "errors_5xx" {
  name                = "alert-${var.container_app_name}-5xx-errors"
  resource_group_name = var.resource_group_name
  scopes              = [var.container_app_id]
  description         = "${var.environment}: more than ${var.errors_5xx_threshold} responses with a 5xx status in 5 minutes."
  severity            = var.severity
  frequency           = "PT1M"
  window_size         = "PT5M"
  auto_mitigate       = true
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.App/containerapps"
    metric_name      = "Requests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = var.errors_5xx_threshold

    dimension {
      name     = "statusCodeCategory"
      operator = "Include"
      values   = ["5xx"]
    }
  }

  action {
    action_group_id = var.action_group_id
  }
}

resource "azurerm_monitor_metric_alert" "latency" {
  name                = "alert-${var.container_app_name}-latency"
  resource_group_name = var.resource_group_name
  scopes              = [var.container_app_id]
  description         = "${var.environment}: average response time above ${var.latency_threshold_ms} ms over 15 minutes."
  severity            = var.severity
  frequency           = "PT5M"
  window_size         = "PT15M"
  auto_mitigate       = true
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.App/containerapps"
    metric_name      = "ResponseTime"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.latency_threshold_ms
  }

  action {
    action_group_id = var.action_group_id
  }
}

resource "azurerm_monitor_metric_alert" "restarts" {
  name                = "alert-${var.container_app_name}-restarts"
  resource_group_name = var.resource_group_name
  scopes              = [var.container_app_id]
  description         = "${var.environment}: a replica has restarted more than ${var.restart_threshold} times."
  severity            = var.severity
  frequency           = "PT5M"
  window_size         = "PT15M"
  auto_mitigate       = true
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.App/containerapps"
    metric_name      = "RestartCount"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = var.restart_threshold
  }

  action {
    action_group_id = var.action_group_id
  }
}

# ---------------------------------------------------------------- log alerts

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "error_rate" {
  name                    = "alert-${var.container_app_name}-error-rate"
  resource_group_name     = var.resource_group_name
  location                = var.location
  display_name            = "${var.environment}: elevated request error rate"
  description             = "${var.environment}: more than ${var.error_rate_threshold_percent}% of requests failed with a 5xx status (at least ${var.error_rate_min_requests} requests in 10 minutes)."
  evaluation_frequency    = "PT5M"
  window_duration         = "PT10M"
  scopes                  = [var.log_analytics_workspace_id]
  severity                = var.severity
  enabled                 = true
  auto_mitigation_enabled = true
  skip_query_validation   = true
  tags                    = var.tags

  criteria {
    query                   = local.error_rate_query
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [var.action_group_id]
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "unhealthy_revision" {
  name                    = "alert-${var.container_app_name}-unhealthy-revision"
  resource_group_name     = var.resource_group_name
  location                = var.location
  display_name            = "${var.environment}: unhealthy revision"
  description             = "${var.environment}: repeated probe failures, back-offs or image pull problems."
  evaluation_frequency    = "PT5M"
  window_duration         = "PT10M"
  scopes                  = [var.log_analytics_workspace_id]
  severity                = var.severity
  enabled                 = true
  auto_mitigation_enabled = true
  skip_query_validation   = true
  tags                    = var.tags

  criteria {
    query                   = local.unhealthy_query
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [var.action_group_id]
  }
}

# ---------------------------------------------------------------- availability (optional)

resource "azurerm_application_insights_standard_web_test" "availability" {
  count = var.enable_availability_test ? 1 : 0

  name                    = "avail-${var.container_app_name}-health"
  resource_group_name     = var.resource_group_name
  location                = var.location
  application_insights_id = var.app_insights_id
  geo_locations           = var.availability_geo_locations
  frequency               = var.availability_frequency_seconds
  timeout                 = 30
  enabled                 = true
  retry_enabled           = true
  description             = "${var.environment}: calls /health from outside Azure's network edge and expects status 200 with the word healthy."
  tags                    = var.tags

  request {
    url       = var.availability_url
    http_verb = "GET"
  }

  validation_rules {
    expected_status_code = 200

    content {
      content_match      = "healthy"
      ignore_case        = true
      pass_if_text_found = true
    }
  }
}

resource "azurerm_monitor_metric_alert" "availability" {
  count = var.enable_availability_test ? 1 : 0

  name                = "alert-${var.container_app_name}-availability"
  resource_group_name = var.resource_group_name
  scopes              = [var.app_insights_id]
  description         = "${var.environment}: the availability test success rate dropped below 90% over 30 minutes."
  severity            = var.severity
  frequency           = "PT15M"
  window_size         = "PT30M"
  auto_mitigate       = true
  tags                = var.tags

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "availabilityResults/availabilityPercentage"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 90
  }

  action {
    action_group_id = var.action_group_id
  }
}