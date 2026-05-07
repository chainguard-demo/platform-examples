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
