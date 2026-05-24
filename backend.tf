terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "stterraformstate001"
    container_name       = "tfstate"
    key                  = "aks-alb-poc.tfstate"
  }
}