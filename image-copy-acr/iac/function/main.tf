terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
    random  = { source = "hashicorp/random" }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

resource "azurerm_storage_account" "main" {
  name                     = "${var.name}sa${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_service_plan" "main" {
  name                = "${var.name}-plan"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

resource "azurerm_linux_function_app" "image_copy" {
  name                       = "${var.name}-image-copy"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  service_plan_id            = azurerm_service_plan.main.id
  storage_account_name       = azurerm_storage_account.main.name
  storage_account_access_key = azurerm_storage_account.main.primary_access_key

  site_config {
    application_stack {
      docker {
        image_name   = var.image_name
        image_tag    = var.image_tag
        registry_url = var.registry_server
      }
    }
  }

  app_settings = {
    WEBSITE_RUN_FROM_PACKAGE         = "0"
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
    WEBSITES_PORT                    = tostring(var.port)
    DOCKER_REGISTRY_SERVER_URL       = "https://${var.registry_server}"
    DOCKER_REGISTRY_SERVER_USERNAME  = var.registry_username
    DOCKER_REGISTRY_SERVER_PASSWORD  = var.registry_password

    ISSUER_URL       = var.issuer_url
    API_ENDPOINT     = var.api_endpoint
    GROUP_NAME       = var.group_name
    GROUP            = var.group
    IDENTITY         = var.identity
    DST_REPO         = var.dst_repo
    IGNORE_REFERRERS = tostring(var.ignore_referrers)
    VERIFY_SIGNATURES = tostring(var.verify_signatures)
    PORT             = tostring(var.port)

    OIDC_TOKEN    = var.oidc_token
    ACR_REGISTRY  = var.acr_registry
    ACR_USERNAME  = var.registry_username
    ACR_PASSWORD  = var.registry_password
  }
}
