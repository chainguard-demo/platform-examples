data "aws_caller_identity" "current" {}

data "chainguard_group" "group" {
  name = var.org_name
}

data "aws_iam_outbound_web_identity_federation" "issuer" {}

resource "chainguard_identity" "aws" {
  parent_id   = data.chainguard_group.group.id
  name        = "aws-lambda-identity"
  description = "Identity for AWS Lambda"

  claim_match {
    issuer  = data.aws_iam_outbound_web_identity_federation.issuer.issuer_identifier
    subject = aws_iam_role.lambda.arn
  }
}

# Create a subscription to notify the Lambda function on changes under the root group.
resource "chainguard_subscription" "subscription" {
  parent_id = data.chainguard_group.group.id
  sink      = aws_lambda_function_url.lambda.function_url
}

data "chainguard_role" "viewer" {
  name = "viewer"
}

resource "chainguard_rolebinding" "viewer" {
  identity = chainguard_identity.aws.id
  role     = data.chainguard_role.viewer.items[0].id
  group    = data.chainguard_group.group.id
}
