terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_container_registry" "target" {
  name                = var.registry_name
  resource_group_name = var.registry_resource_group_name
}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_container_app_environment" "main" {
  name                = "${var.name}-env"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_container_app" "image_copy" {
  name                         = "${var.name}-image-copy"
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"

  secret {
    name  = "oidc-token"
    value = var.oidc_token
  }

  identity {
    type = "SystemAssigned"
  }

  registry {
    server   = var.registry_server
    identity = "system"
  }

  template {
    container {
      name   = "image-copy"
      image  = var.image
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "ISSUER_URL"
        value = var.issuer_url
      }
      env {
        name  = "API_ENDPOINT"
        value = var.api_endpoint
      }
      env {
        name  = "GROUP_NAME"
        value = var.group_name
      }
      env {
        name  = "GROUP"
        value = var.group
      }
      env {
        name  = "IDENTITY"
        value = var.identity
      }
      env {
        name  = "DST_REPO"
        value = var.dst_repo
      }
      env {
        name  = "IGNORE_REFERRERS"
        value = tostring(var.ignore_referrers)
      }
      env {
        name  = "VERIFY_SIGNATURES"
        value = tostring(var.verify_signatures)
      }
      env {
        name  = "PORT"
        value = tostring(var.port)
      }
      env {
        name        = "OIDC_TOKEN"
        secret_name = "oidc-token"
      }
      env {
        name  = "ACR_REGISTRY"
        value = var.acr_registry
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = var.port

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = data.azurerm_container_registry.target.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_container_app.image_copy.identity[0].principal_id
}

resource "azurerm_role_assignment" "acr_push" {
  scope                = data.azurerm_container_registry.target.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_container_app.image_copy.identity[0].principal_id
}
