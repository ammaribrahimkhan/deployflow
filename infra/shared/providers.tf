terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.10"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-deployflow-tfstate-eus2"
    storage_account_name = "stdfstateammar03"
    container_name       = "tfstate"
    key                  = "shared.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  # The subscription comes from the ARM_SUBSCRIPTION_ID environment variable.
  resource_provider_registrations = "none"

  features {}
}