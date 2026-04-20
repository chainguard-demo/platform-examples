locals {
  acr_id           = var.existing_acr_name != "" ? data.azurerm_container_registry.existing[0].id : azurerm_container_registry.new[0].id
  acr_login_server = var.existing_acr_name != "" ? data.azurerm_container_registry.existing[0].login_server : azurerm_container_registry.new[0].login_server

  # Scope for role assignments: the resource group that owns the ACR.
  acr_rg_id = var.existing_acr_name != "" ? data.azurerm_resource_group.acr_rg[0].id : azurerm_resource_group.main.id

  image_repo = "${local.acr_login_server}/image-copy-acr/copier"
  image_tag  = "latest"
}


# ── Resource group ───────────────────────────────────────────────────────────

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_resource_group" "main" {
  name     = "rg-cgr-imagereplication-${random_string.suffix.result}"
  location = var.location
}

# ── ACR: use an existing registry or create a new one ───────────────────────
#
# Set existing_acr_name + existing_acr_resource_group to reuse an ACR that
# was provisioned outside of this module.  Leave both blank (the default) to
# have Terraform create a new Basic-tier ACR in the generated resource group.
#
# Before running `terraform apply`, authenticate Docker to the registry:
#   az acr login --name <registry_name>
# ---------------------------------------------------------------------------

data "azurerm_container_registry" "existing" {
  count               = var.existing_acr_name != "" ? 1 : 0
  name                = var.existing_acr_name
  resource_group_name = var.existing_acr_resource_group
}

resource "azurerm_container_registry" "new" {
  count               = var.existing_acr_name == "" ? 1 : 0
  name                = "acrcgr${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
}

# Needed only when reusing an ACR in a different resource group.
data "azurerm_resource_group" "acr_rg" {
  count = var.existing_acr_name != "" ? 1 : 0
  name  = var.existing_acr_resource_group
}

# ── Container image ──────────────────────────────────────────────────────────
#
# Option A (active): build from the Dockerfile in the repo root.
# Requires `az acr login --name <registry>` before `terraform apply`.

resource "null_resource" "docker_build_push" {
  triggers = {
    dockerfile = filesha256("${path.cwd}/../Dockerfile")
    main_go    = filesha256("${path.cwd}/../main.go")
  }

  provisioner "local-exec" {
    command = <<-EOT
      docker build --platform linux/amd64 --pull -t ${local.image_repo}:${local.image_tag} ${path.cwd}/..
      docker push ${local.image_repo}:${local.image_tag}
    EOT
  }
}

# Option B (commented out): build with KO directly from source.
# Uncomment and remove the null_resource above once the importpath is
# resolvable from this module (requires the module to be published).
#
# resource "ko_build" "image" {
#   repo        = "${local.acr_login_server}/image-copy-acr/copier"
#   importpath  = "github.com/chainguard-dev/platform-examples/image-copy-acr"
#   working_dir = "${path.cwd}/.."
#   sbom        = "none"
# }

# ── Managed identity ─────────────────────────────────────────────────────────

resource "azurerm_user_assigned_identity" "mi" {
  name                = "mi-cgr-acr-pushpull"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

# AcrPull and AcrPush at the resource-group level that contains the ACR,
# so the identity can push/pull any repository in that registry.
resource "azurerm_role_assignment" "acr_pull" {
  scope                = local.acr_rg_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.mi.principal_id
}

resource "azurerm_role_assignment" "acr_push" {
  scope                = local.acr_rg_id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.mi.principal_id
}

# ── Container App Environment (consumption-based) ────────────────────────────

resource "azurerm_container_app_environment" "main" {
  name                = "ace-cgr-replicator"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  # No workload_profile block = consumption plan (serverless).
}

# ── Container App ────────────────────────────────────────────────────────────

resource "azurerm_container_app" "replicator" {
  name                         = "ca-cgr-replicator"
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"

  secret {
    name  = "chainguard-identity"
    value = chainguard_identity.azure.id
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.mi.id]
  }

  # Pull the KO-built image from ACR using the managed identity.
  registry {
    server   = local.acr_login_server
    identity = azurerm_user_assigned_identity.mi.id
  }

  template {
    min_replicas = 1
    max_replicas = 2

    container {
      name   = "replicator"
      image  = "${local.image_repo}:${local.image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "ISSUER_URL"
        value = "https://issuer.enforce.dev"
      }
      env {
        name  = "API_ENDPOINT"
        value = "https://console-api.enforce.dev"
      }
      env {
        name  = "GROUP_NAME"
        value = var.chainguard_org
      }
      env {
        name  = "GROUP"
        value = data.chainguard_group.group.id
      }
      env {
        name        = "IDENTITY"
        secret_name = "chainguard-identity"
      }
      env {
        name  = "DST_REPO"
        value = "${local.acr_login_server}/${var.dst_repo_prefix}"
      }
      env {
        name  = "ACR_REGISTRY"
        value = local.acr_login_server
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
        value = "8080"
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.mi.client_id
      }
      env {
        name  = "AZURE_TENANT_ID"
        value = data.azurerm_client_config.current.tenant_id
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8080

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}
