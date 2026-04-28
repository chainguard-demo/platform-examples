terraform {
  required_providers {
    azurerm    = { source = "hashicorp/azurerm" }
    azuread    = { source = "hashicorp/azuread" }
    chainguard = { source = "chainguard-dev/chainguard" }
    ko         = { source = "ko-build/ko" }
    random     = { source = "hashicorp/random" }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.sub_id

  # ── Azure Government (optional) ────────────────────────────────────────────
  # Uncomment to target Azure Government Cloud.
  #
  # environment     = "usgovernment"
}

provider "azuread" {}

provider "chainguard" {}

provider "ko" {}

data "azurerm_client_config" "current" {}
