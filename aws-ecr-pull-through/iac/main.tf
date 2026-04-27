terraform {
  required_providers {
    aws        = { source = "hashicorp/aws" }
    chainguard = { source = "chainguard-dev/chainguard" }
    ko         = { source = "ko-build/ko" }
    random     = { source = "hashicorp/random" }
  }
}

resource "random_string" "suffix" {
  count   = var.suffix == "" ? 1 : 0
  length  = 8
  upper   = false
  numeric = true
  special = false
}

locals {
  suffix                     = var.suffix != "" ? var.suffix : random_string.suffix[0].result
  name                       = "chainguard-pull-through-${local.suffix}"
  ecr_repository_prefix      = var.ecr_repository_prefix != "" ? var.ecr_repository_prefix : "chainguard-${local.suffix}"
  upstream_repository_prefix = var.upstream_repository_prefix != "" ? var.upstream_repository_prefix : var.org_name
}
