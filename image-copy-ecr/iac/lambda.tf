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

data "aws_iam_policy_document" "ecr-pusher" {
  // Permissions needed to push to the ECR repository.
  // https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-push.html#image-push-iam

  statement {
    effect = "Allow"
    actions = [
      "ecr:CreateRepository", // Also need to create repositories under the target repository.

      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:GetRepositoryPolicy",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
      "ecr:DescribeImages",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage"
    ]
    resources = [
      aws_ecr_repository.repo.arn,
      "${aws_ecr_repository.repo.arn}/*"
    ]
  }
  statement {
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy" "lambda" {
  name = "AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role" "lambda" {
  name               = "image-copy"
  assume_role_policy = data.aws_iam_policy_document.lambda.json
  inline_policy {
    name   = "ecr-pusher"
    policy = data.aws_iam_policy_document.ecr-pusher.json
  }
  managed_policy_arns = [data.aws_iam_policy.lambda.arn]
}

resource "aws_ecr_repository_policy" "policy" {
  repository = aws_ecr_repository.repo.name
  policy     = data.aws_iam_policy_document.lambda.json
}

resource "aws_ecr_repository" "repo" {
  name                 = var.dst_repo
  image_tag_mutability = var.immutable_tags ? "IMMUTABLE" : "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }
}

// Create a sub-repository for the image-copy lambda code.
resource "aws_ecr_repository" "copier-repo" {
  name                 = "${var.dst_repo}/image-copy"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }
}

locals {
  lambda_image_uri = "${aws_ecr_repository.copier_repo.repository_url}:${random_string.tag.result}"
  // the sha1 hash value is used to detect changes to the source code so that
  // the provider knows when to rebuild the lambda image with a new tag
  source_hash      = sha1(join("", [for f in fileset("${path.module}/..", "*") : filesha1("${path.module}/../${f}")]))
  // Using a local for the lambda breaks a cyclic dependency between
  // chainguard_identity.aws and aws_lambda_function.lambda
  lambda_name = "image-copy"
}

resource "random_string" "tag" {
  keepers = {
    dir_sha1 = local.source_hash
  }
  length  = 4
  special = false
  upper   = false
}

resource "docker_registry_image" "cgr_ecr_mirror" {
  name          = docker_image.image.name
  keep_remotely = true
}

resource "docker_image" "image" {
  name = local.lambda_image_uri
  build {
    context  = "${path.module}/.."
    tag      = ["latest", random_string.tag.result]
    platform = "linux/amd64"
  }
  triggers = {
    dir_sha1 = local.source_hash
  }
}

data "aws_region" "current" {}

resource "aws_lambda_function" "lambda" {
  function_name = local.lambda_name
  role          = aws_iam_role.lambda.arn

  package_type = "Image"
  image_uri    = local.lambda_image_uri
  depends_on   = [docker_registry_image.cgr_ecr_mirror]

  timeout = 300

  environment {
    variables = {
      GROUP_NAME       = var.group_name
      GROUP            = data.chainguard_group.group.id
      IDENTITY         = chainguard_identity.aws.id
      ISSUER_URL       = "https://issuer.enforce.dev"
      API_ENDPOINT     = "https://console-api.enforce.dev"
      DST_REPO         = var.dst_repo
      FULL_DST_REPO    = aws_ecr_repository.repo.repository_url
      REGION           = data.aws_region.current.name
      IMMUTABLE_TAGS   = var.immutable_tags
      IGNORE_REFERRERS = var.ignore_referrers
    }
  }
}

resource "aws_lambda_function_url" "lambda" {
  function_name      = aws_lambda_function.lambda.function_name
  authorization_type = "NONE"
}
