data "aws_iam_policy_document" "lambda" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy" "lambda" {
  name = "AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role" "lambda" {
  name                = "print-events"
  assume_role_policy  = data.aws_iam_policy_document.lambda.json
  managed_policy_arns = [data.aws_iam_policy.lambda.arn]
}

resource "aws_iam_role_policy" "web_identity_token_policy" {
  name = "print-events-web-identity-token-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:GetWebIdentityToken"
        Resource = "*"
        Condition = {
          "ForAnyValue:StringEquals" = {
            "sts:IdentityTokenAudience" = "https://issuer.enforce.dev"
          }
          "NumericLessThanEquals" : {
            "sts:DurationSeconds" : 300
          }
        }
      }
    ]
  })
}

locals {
  source_hash = sha1(join("", [
    filesha1("${path.module}/../Dockerfile"),
    filesha1("${path.module}/../lambda_function.py"),
    filesha1("${path.module}/../requirements.txt"),
  ]))
}

resource "aws_ecr_repository" "lambda" {
  name         = "print-events"
  force_delete = true
}

provider "docker" {
  registry_auth {
    address     = split("/", aws_ecr_repository.lambda.repository_url)[0]
    config_file = pathexpand("~/.docker/config.json")
  }
}

resource "docker_image" "lambda" {
  name = aws_ecr_repository.lambda.repository_url
  build {
    context    = abspath("${path.module}/..")
    dockerfile = abspath("${path.module}/../Dockerfile")
    platform   = "linux/amd64"
  }
  triggers = {
    source_hash = local.source_hash
  }
}

resource "docker_registry_image" "lambda" {
  name          = docker_image.lambda.name
  keep_remotely = true
  triggers = {
    image_id = docker_image.lambda.image_id
  }
}

resource "aws_lambda_function" "lambda" {
  function_name = "print-events"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = "${docker_registry_image.lambda.name}@${docker_registry_image.lambda.sha256_digest}"
  timeout       = 30

  environment {
    variables = {
      ORG_ID   = data.chainguard_group.group.id
      IDENTITY = chainguard_identity.aws.id
      CE_TYPES = join(",", var.ce_types)
    }
  }
}

resource "aws_lambda_function_url" "lambda" {
  function_name      = aws_lambda_function.lambda.function_name
  authorization_type = "NONE"
}
