# Monthly budget with email alerts. Budgets warn you; they do not stop spending.
# If your subscription type does not support budgets, set enable_budget to false.

variable "enable_budget" {
  description = "Create the monthly subscription budget."
  type        = bool
  default     = true
}

variable "monthly_budget" {
  description = "Monthly budget amount in the billing currency."
  type        = number
  default     = 20
}

variable "budget_start_date" {
  description = "First day of a month (UTC) when the budget starts."
  type        = string
  default     = "2026-11-01T00:00:00Z"
}

data "azurerm_subscription" "budget_scope" {}

resource "azurerm_consumption_budget_subscription" "monthly" {
  count = var.enable_budget ? 1 : 0

  name            = "budget-deployflow-monthly"
  subscription_id = data.azurerm_subscription.budget_scope.id
  amount          = var.monthly_budget
  time_grain      = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  notification {
    enabled        = true
    threshold      = 50.0
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 80.0
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100.0
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100.0
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.alert_email]
  }
}