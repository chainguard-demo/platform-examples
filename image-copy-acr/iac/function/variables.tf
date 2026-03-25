variable "name" {
  description = "Name prefix for resources."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Resource group name."
  type        = string
}

variable "image_name" {
  description = "Container image name without tag, e.g. myregistry.azurecr.io/image-copy-acr."
  type        = string
}

variable "image_tag" {
  description = "Container image tag, e.g. latest."
  type        = string
  default     = "latest"
}

variable "registry_server" {
  description = "ACR registry server, e.g. myregistry.azurecr.io."
  type        = string
}

variable "registry_username" {
  description = "ACR username."
  type        = string
}

variable "registry_password" {
  description = "ACR password or token."
  type        = string
  sensitive   = true
}

variable "acr_registry" {
  description = "Optional ACR registry hostname override."
  type        = string
  default     = ""
}

variable "issuer_url" {
  description = "Chainguard issuer URL."
  type        = string
  default     = "https://issuer.enforce.dev"
}

variable "api_endpoint" {
  description = "Chainguard API endpoint."
  type        = string
  default     = "https://console-api.enforce.dev"
}

variable "group_name" {
  description = "Chainguard group name that owns the source repos."
  type        = string
}

variable "group" {
  description = "Chainguard group ID."
  type        = string
}

variable "identity" {
  description = "Chainguard identity ID."
  type        = string
}

variable "dst_repo" {
  description = "Destination repo prefix in ACR, including registry hostname."
  type        = string
}

variable "ignore_referrers" {
  description = "Whether to ignore signatures/attestations."
  type        = bool
  default     = false
}

variable "verify_signatures" {
  description = "Whether to verify signatures before copying."
  type        = bool
  default     = false
}

variable "port" {
  description = "Listening port."
  type        = number
  default     = 8080
}

variable "oidc_token" {
  description = "OIDC token used to exchange for a Chainguard token."
  type        = string
  sensitive   = true
}
