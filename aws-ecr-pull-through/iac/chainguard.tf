data "chainguard_group" "group" {
  name = var.org_name
}

# AWS account's outbound web identity federation issuer URL.
# Format: https://<uuid>.tokens.sts.global.api.aws (per-account).
data "aws_iam_outbound_web_identity_federation" "current" {}

# Chainguard identity for the rotator Lambda. Bound to OIDC tokens issued by
# AWS for the Lambda's IAM role: the token's `iss` is the per-account AWS
# federation issuer, and `sub` is the role ARN.
resource "chainguard_identity" "aws" {
  parent_id   = data.chainguard_group.group.id
  name        = local.name
  description = "Identity for the ${local.name} pull-token rotator Lambda"

  claim_match {
    issuer  = data.aws_iam_outbound_web_identity_federation.current.issuer_identifier
    subject = aws_iam_role.lambda.arn
  }
}

# Built-in role with the capabilities needed to mint a pull token (create the
# backing identity and bind the chosen role to it).
data "chainguard_role" "pull_token_creator" {
  name = "registry.pull_token_creator"
}

resource "chainguard_rolebinding" "creator" {
  identity = chainguard_identity.aws.id
  role     = data.chainguard_role.pull_token_creator.items[0].id
  group    = data.chainguard_group.group.id
}

# Custom role covering only the capabilities the rotator needs that aren't
# already in an off-the-shelf role (currently just identity.delete, used for
# cleaning up expired pull tokens). Using registry.pull_token_creator for
# everything it grants means we automatically pick up any future changes to
# that role without having to update this module.
resource "chainguard_role" "cleaner" {
  parent_id   = data.chainguard_group.group.id
  name        = local.name
  description = "Allows the rotator Lambda to delete expired pull-token identities."
  capabilities = [
    "identity.delete",
  ]
}

resource "chainguard_rolebinding" "cleaner" {
  identity = chainguard_identity.aws.id
  role     = chainguard_role.cleaner.id
  group    = data.chainguard_group.group.id
}
