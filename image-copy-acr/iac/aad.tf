data "azuread_client_config" "current" {}

locals {
  _client_id     = one(azuread_application.chainguard_audience[*].client_id)
  token_scope    = var.create_application ? "api://${local._client_id}" : var.token_scope
  claim_match_audience = var.create_application ? local._client_id : var.claim_match_audience
  claim_match_issuer   = var.claim_match_issuer != "" ? var.claim_match_issuer : "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/v2.0"
}

# A minimal Azure AD application registration with no API permissions and no
# exposed scopes. Its sole purpose is to give us a unique, tenant-specific
# audience for tokens exchanged with Chainguard's STS.
#
# Because the app has no permissions, a token issued for this audience cannot
# be used to access any Azure resource. And because the client ID is specific
# to this deployment, the token will not be accepted by any other federated
# identity service unless it is explicitly configured to trust this exact app.
resource "azuread_application" "chainguard_audience" {
  count        = var.create_application ? 1 : 0
  display_name = "cgr-image-copier-chainguard-audience"
  owners       = [data.azuread_client_config.current.object_id]

  api {
    requested_access_token_version = 2
  }

  lifecycle {
    ignore_changes = [identifier_uris]
  }
}

# A service principal is required for Azure AD to recognise the application as
# a valid token audience when managed identity requests a token for it.
resource "azuread_service_principal" "chainguard_audience" {
  count     = var.create_application ? 1 : 0
  client_id = azuread_application.chainguard_audience[0].client_id
  owners    = [data.azuread_client_config.current.object_id]
}

# Register api://<client-id> as the identifier URI so Azure AD resolves
# it as a valid resource when managed identity requests a token for it.
resource "azuread_application_identifier_uri" "chainguard_audience" {
  count          = var.create_application ? 1 : 0
  application_id = azuread_application.chainguard_audience[0].id
  identifier_uri = "api://${azuread_application.chainguard_audience[0].client_id}"
}
