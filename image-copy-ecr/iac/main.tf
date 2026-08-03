terraform {
  required_providers {
    aws        = { source = "hashicorp/aws" }
    chainguard = { source = "chainguard-dev/chainguard" }
    docker     = { source = "kreuzwerker/docker" }
    random     = { source  = "hashicorp/random" }
  }
}
