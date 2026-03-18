terraform {
  required_version = ">= 1.14.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.64"
    }
  }

  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  use_oidc                        = true
  resource_provider_registrations = "none"
}
