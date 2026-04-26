variable "location" {
  description = "Azure region to deploy into."
  type        = string
  default     = "eastus"
}

# ── Chainguard ───────────────────────────────────────────────────────────────

variable "chainguard_org" {
  description = "Chainguard organization name to subscribe to (e.g. 'your.org.com')."
  type        = string
}

# ── Chainguard token audience ────────────────────────────────────────────────

variable "create_application" {
  description = "Create a dedicated Azure AD application to use as the token audience for Chainguard STS exchange. Set to false to supply token_scope and claim_match_audience directly."
  type        = bool
  default     = true
}

variable "token_scope" {
  description = "OAuth2 scope passed to GetToken when requesting the managed identity token (e.g. 'api://<client-id>'). Required when create_application is false."
  type        = string
  default     = ""

  validation {
    condition     = var.create_application || var.token_scope != ""
    error_message = "token_scope must be set when create_application is false."
  }
}

variable "claim_match_audience" {
  description = "Audience value to match in the Chainguard claim_match (the 'aud' claim of the issued token). Required when create_application is false."
  type        = string
  default     = ""

  validation {
    condition     = var.create_application || var.claim_match_audience != ""
    error_message = "claim_match_audience must be set when create_application is false."
  }
}

variable "claim_match_issuer" {
  description = "Issuer to match in the Chainguard claim_match. Defaults to the v2 tenant-specific Azure AD issuer when empty."
  type        = string
  default     = ""
}

# ── Image replication ────────────────────────────────────────────────────────

variable "dst_repo_prefix" {
  description = "Path prefix inside the ACR for copied images (e.g. 'mirrors'). Images land at <acr_login_server>/<dst_repo_prefix>/<image>:<tag>."
  type        = string
  default     = "chainguard"
}

variable "ignore_referrers" {
  description = "Skip copying signature and attestation tags (tags that start with 'sha256-')."
  type        = bool
  default     = false
}

variable "verify_signatures" {
  description = "Verify Chainguard image signatures before copying. Requires a network call to the Rekor transparency log."
  type        = bool
  default     = false
}

# ── ACR: optional existing registry ─────────────────────────────────────────
#
# Leave both variables at their defaults ("") to have Terraform create a new
# Basic-tier ACR inside the generated resource group.
#
# Set both variables to reuse an ACR that was provisioned outside of this
# module (e.g. a shared registry managed by a platform team).  The identity
# will still receive AcrPull/AcrPush at the resource-group level of that ACR.

variable "existing_acr_name" {
  description = "Name of an existing ACR to target (e.g. 'myregistry'). Leave blank to create a new one."
  type        = string
  default     = ""
}

variable "existing_acr_resource_group" {
  description = "Resource group containing the existing ACR. Required when existing_acr_name is set."
  type        = string
  default     = ""

  validation {
    condition     = var.existing_acr_name == "" || var.existing_acr_resource_group != ""
    error_message = "existing_acr_resource_group must be set when existing_acr_name is provided."
  }
}

variable "sub_id" {
  description = "Azure subscription ID"
  type        = string
  default     = ""
}
