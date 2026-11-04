# Lets the dashboard read cost data and budgets. This role cannot change anything.
resource "azurerm_role_assignment" "cost_reader" {
  scope                            = data.azurerm_subscription.current.id
  role_definition_name             = "Cost Management Reader"
  principal_id                     = azurerm_user_assigned_identity.dashboard.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}