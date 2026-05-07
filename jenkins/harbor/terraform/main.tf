terraform {
  required_providers {
    harbor = {
      source  = "goharbor/harbor"
      version = "~> 3.10"
    }
  }
}

# The Harbor admin password matches the Helm chart default. If you override
# the chart value `harborAdminPassword`, change this too.
# `insecure = true` skips TLS verification — the chart issues a self-signed
# cert (see harbor/cg/helm/values.template for why we can't run HTTP).
provider "harbor" {
  url      = "https://localhost"
  username = "admin"
  password = "Harbor12345"
  insecure = true
}

# Register cgr.dev as an upstream registry so we can use it as a proxy cache
# source. Harbor authenticates to cgr.dev with the supplied pull token.
resource "harbor_registry" "cgr_dev" {
  provider_name = "docker-registry"
  name          = "cgr.dev"
  endpoint_url  = "https://cgr.dev"
  access_id     = var.chainguard_username
  access_secret = var.chainguard_pull_token
}

# Public proxy-cache project. Anonymous pulls of
# `localhost/cgr-proxy/<org>/<image>:<tag>` lazily fetch from cgr.dev on
# first hit and cache locally; subsequent pulls hit Harbor's local copy.
# (Harbor's default `library` project is reused for pushes — no extra
# resource needed.)
resource "harbor_project" "cgr_proxy" {
  name        = "cgr-proxy"
  public      = true
  registry_id = harbor_registry.cgr_dev.registry_id
}
