resource "azurerm_resource_group" "this" {
  name     = "rg-${var.project}-${var.environment}"
  location = var.location

  tags = {
    environment = var.environment
    project     = var.project
    managed_by  = "terraform"
    owner       = "jpvieirah"
  }
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.project}-${var.environment}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = ["10.1.0.0/16"]

  subnet {
    name             = "snet-default"
    address_prefixes = ["10.1.1.0/24"]
  }

  tags = {
    environment = var.environment
    project     = var.project
    managed_by  = "terraform"
  }
}
