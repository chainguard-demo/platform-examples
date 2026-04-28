# Look up the Chainguard group by name.
data "chainguard_group" "group" {
  name = var.chainguard_org
}

# Create a Chainguard identity that trusts the Azure AD token issued to the
# managed identity (mi-cgr-acr-pushpull).
#
# The Container App requests a managed identity token using local.effective_scope
# as the OAuth2 scope, and Chainguard's STS validates the resulting JWT against
# the claim_match below. When create_application = true (the default), scope and
# audience are derived automatically from the created app registration.
resource "chainguard_identity" "azure" {
  parent_id   = data.chainguard_group.group.id
  name        = "azure-container-app"
  description = "Identity for the image-copy-acr Container App in Azure"

  claim_match {
    issuer   = local.claim_match_issuer
    subject  = azurerm_user_assigned_identity.mi.principal_id
    audience = local.claim_match_audience
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

# Grant the identity viewer access so it can list IAM service principals
# for signature verification (APKO_BUILDER, CATALOG_SYNCER).
data "chainguard_role" "viewer" {
  name = "viewer"
}

resource "chainguard_rolebinding" "viewer" {
  identity = chainguard_identity.azure.id
  role     = data.chainguard_role.viewer.items[0].id
  group    = data.chainguard_group.group.id
}

# Subscribe to push events under the group.  Chainguard will POST a
# CloudEvent to the Container App's public URL whenever an image is pushed
# to any repository in the group.
resource "chainguard_subscription" "subscription" {
  parent_id = data.chainguard_group.group.id
  sink      = "https://${azurerm_container_app.replicator.ingress[0].fqdn}"
}
