output "alert_rule_names" {
  description = "Names of the alert rules created for this app."
  value = concat(
    [
      azurerm_monitor_metric_alert.errors_5xx.name,
      azurerm_monitor_metric_alert.latency.name,
      azurerm_monitor_metric_alert.restarts.name,
      azurerm_monitor_scheduled_query_rules_alert_v2.error_rate.name,
      azurerm_monitor_scheduled_query_rules_alert_v2.unhealthy_revision.name,
    ],
    azurerm_monitor_metric_alert.availability[*].name
  )
}