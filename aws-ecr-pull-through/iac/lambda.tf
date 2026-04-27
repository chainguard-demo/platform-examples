data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── Lambda IAM ──────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_secret" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:PutSecretValue",
    ]
    resources = [aws_secretsmanager_secret.cgr.arn]
  }
}

# Allow the Lambda to ask AWS STS for an OIDC token addressed to Chainguard.
# Outbound identity federation must be enabled on the AWS account.
data "aws_iam_policy_document" "lambda_get_web_identity_token" {
  statement {
    effect    = "Allow"
    actions   = ["sts:GetWebIdentityToken"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "sts:IdentityTokenAudience"
      values   = ["https://issuer.enforce.dev"]
    }
    condition {
      test     = "NumericLessThanEquals"
      variable = "sts:DurationSeconds"
      values   = ["300"]
    }
  }
}

data "aws_iam_policy" "lambda_basic" {
  name = "AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role" "lambda" {
  name               = local.name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "lambda_secret" {
  name   = "secrets-${local.suffix}"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_secret.json
}

resource "aws_iam_role_policy" "lambda_get_web_identity_token" {
  name   = "get-web-identity-token-${local.suffix}"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_get_web_identity_token.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = data.aws_iam_policy.lambda_basic.arn
}

# ── Container image ─────────────────────────────────────────────────────────

resource "ko_build" "image" {
  repo        = aws_ecr_repository.rotator.repository_url
  importpath  = "github.com/chainguard-dev/platform-examples/aws-ecr-pull-through"
  working_dir = "${path.module}/.."
  sbom        = "none"
}

# ── Lambda function ─────────────────────────────────────────────────────────

resource "aws_lambda_function" "rotator" {
  function_name = local.name
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = ko_build.image.image_ref
  timeout       = 60
  memory_size   = 256

  environment {
    variables = {
      ISSUER_URL      = "https://issuer.enforce.dev"
      API_ENDPOINT    = "https://console-api.enforce.dev"
      ORG_NAME        = var.org_name
      GROUP           = data.chainguard_group.group.id
      IDENTITY        = chainguard_identity.aws.id
      SECRET_ID       = aws_secretsmanager_secret.cgr.arn
      TOKEN_TTL       = var.token_ttl
      PULL_TOKEN_NAME = local.name
    }
  }
}

# ── Bootstrap invocation (runs once at apply, re-runs on lambda/secret changes) ─

resource "aws_lambda_invocation" "bootstrap" {
  function_name = aws_lambda_function.rotator.function_name
  input         = jsonencode({})

  triggers = {
    secret  = aws_secretsmanager_secret.cgr.arn
    version = aws_lambda_function.rotator.version
  }

  depends_on = [
    aws_secretsmanager_secret_version.cgr,
    aws_iam_role_policy.lambda_secret,
    aws_iam_role_policy.lambda_get_web_identity_token,
    aws_iam_role_policy_attachment.lambda_basic,
    chainguard_rolebinding.creator,
    chainguard_rolebinding.cleaner,
  ]
}

# ── Recurring rotation (EventBridge Scheduler) ──────────────────────────────

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "scheduler_invoke" {
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.rotator.arn]
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name   = "invoke-${local.suffix}"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler_invoke.json
}

resource "aws_scheduler_schedule" "rotate" {
  name                = local.name
  schedule_expression = var.rotation_schedule

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.rotator.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}
