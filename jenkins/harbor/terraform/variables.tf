variable "chainguard_username" {
  type        = string
  description = "Username portion of the Chainguard pull token Harbor uses to fetch from cgr.dev."
  sensitive   = true
}

variable "chainguard_pull_token" {
  type        = string
  description = "Password (JWT) portion of the Chainguard pull token Harbor uses to fetch from cgr.dev."
  sensitive   = true
}

variable "chainguard_organization_name" {
  type        = string
  description = "Chainguard org being proxied (matches CHAINGUARD_ORG used elsewhere in the demo)."
}

variable "harbor_admin_password" {
  type        = string
  description = "Harbor admin password. Must match the Helm chart's harborAdminPassword value (deploy.sh keeps these in sync via HARBOR_ADMIN_PASSWORD)."
  sensitive   = true
}
