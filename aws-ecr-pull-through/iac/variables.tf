variable "org_name" {
  type        = string
  description = "Chainguard organization name to mint pull tokens under (e.g. 'your.org.com')."
}

variable "suffix" {
  type        = string
  default     = ""
  description = "Suffix appended to every resource name in this module. Auto-generated as a random string when empty."
}

variable "ecr_repository_prefix" {
  type        = string
  default     = ""
  description = "Local ECR namespace for cached images. Pulls go to <account>.dkr.ecr.<region>.amazonaws.com/<ecr_repository_prefix>/<image>. Defaults to 'chainguard-<name>' when empty."
}

variable "upstream_repository_prefix" {
  type        = string
  default     = ""
  description = "Upstream repository prefix on cgr.dev. Defaults to var.org_name when empty."
}

variable "token_ttl" {
  type        = string
  default     = "336h"
  description = "Lifetime of each minted pull token as a Go duration string (e.g. '336h' for 14 days)."
}

variable "rotation_schedule" {
  type        = string
  default     = "rate(1 day)"
  description = "EventBridge schedule expression that triggers rotation."
}
