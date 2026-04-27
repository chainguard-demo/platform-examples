# Secrets Manager secret holding the cgr.dev pull credential. The Lambda
# rotates secret_string on a schedule; the placeholder below is overwritten
# on first invocation. The secret name must start with "ecr-pullthroughcache/"
# so ECR's service-linked role is allowed to read it.
resource "aws_secretsmanager_secret" "cgr" {
  name = "ecr-pullthroughcache/${local.name}"
}

resource "aws_secretsmanager_secret_version" "cgr" {
  secret_id     = aws_secretsmanager_secret.cgr.id
  secret_string = jsonencode({ username = "_token", accessToken = "placeholder" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ECR pull-through cache rule pointing at cgr.dev/<group>. ECR will lazily
# create cached repositories under <account>.dkr.ecr.<region>.amazonaws.com/<ecr_repository_prefix>/
# whenever a client pulls an image that hasn't been cached yet.
resource "aws_ecr_pull_through_cache_rule" "cgr" {
  ecr_repository_prefix      = local.ecr_repository_prefix
  upstream_registry_url      = "cgr.dev"
  upstream_repository_prefix = local.upstream_repository_prefix
  credential_arn             = aws_secretsmanager_secret.cgr.arn
}

# Dedicated repository for the rotator Lambda's image. Kept separate from the
# pull-through cache prefix so cached images and rotator images don't share a
# namespace.
resource "aws_ecr_repository" "rotator" {
  name         = local.name
  force_delete = true

  image_scanning_configuration {
    scan_on_push = false
  }
}
