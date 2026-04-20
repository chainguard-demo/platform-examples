# Look up the Chainguard group by name.
data "chainguard_group" "group" {
  name = var.chainguard_org
}

# Create a Chainguard identity that trusts the Azure AD token issued to the
# managed identity (mi-cgr-acr-pushpull).
#
# When the Container App calls the Azure IMDS endpoint
#   http://169.254.169.254/metadata/identity/oauth2/token
# it receives a JWT signed by Azure AD whose claims are:
#   iss = https://login.microsoftonline.com/<tenant_id>/v2.0
#   sub = <principal_id of the managed identity>
#
# The Chainguard STS will accept that token and exchange it for a
# Chainguard access token scoped to this identity.
resource "chainguard_identity" "azure" {
  parent_id   = data.chainguard_group.group.id
  name        = "azure-container-app"
  description = "Identity for the image-copy-acr Container App in Azure"

  claim_match {
    issuer   = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/v2.0"
    subject  = azurerm_user_assigned_identity.mi.principal_id
    audience = "fb60f99c-7a34-4190-8149-302f77469936"
  }
}

# Grant the identity permission to pull from the Chainguard registry.
data "chainguard_role" "puller" {
  name = "registry.pull"
}

resource "chainguard_rolebinding" "puller" {
  identity = chainguard_identity.azure.id
  role     = data.chainguard_role.puller.items[0].id
  group    = data.chainguard_group.group.id
}

# Subscribe to push events under the group.  Chainguard will POST a
# CloudEvent to the Container App's public URL whenever an image is pushed
# to any repository in the group.
resource "chainguard_subscription" "subscription" {
  parent_id = data.chainguard_group.group.id
  sink      = "https://${azurerm_container_app.replicator.ingress[0].fqdn}"
}
