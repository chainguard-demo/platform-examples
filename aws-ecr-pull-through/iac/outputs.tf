output "suffix" {
  value       = local.suffix
  description = "Suffix used across all resource names in this deployment."
}

output "ecr_repository_prefix" {
  value       = local.ecr_repository_prefix
  description = "ECR namespace where cached images appear (cached repos are auto-created by ECR on first pull)."
}

output "pull_through_cache_uri" {
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com/${local.ecr_repository_prefix}"
  description = "Base URI to pull images through. Append /<image>:<tag> as you would on cgr.dev."
}

output "secret_arn" {
  value       = aws_secretsmanager_secret.cgr.arn
  description = "ARN of the Secrets Manager secret backing the pull-through cache rule."
}

output "rotator_function_name" {
  value       = aws_lambda_function.rotator.function_name
  description = "Lambda function name for the rotator."
}

output "chainguard_identity_id" {
  value       = chainguard_identity.aws.id
  description = "Chainguard identity ID for the rotator Lambda."
}
