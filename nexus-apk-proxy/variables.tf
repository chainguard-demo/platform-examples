variable "nexus_url" {
  description = "Base URL of the Nexus Repository Manager instance (e.g. http://localhost:8081)"
  type        = string
}

variable "nexus_username" {
  description = "Nexus admin username"
  type        = string
  default     = "admin"
}

variable "nexus_password" {
  description = "Nexus admin password"
  type        = string
  sensitive   = true
}

variable "chainguard_organization" {
  description = "Chainguard organization name as shown in the Chainguard Console (used to form https://apk.cgr.dev/<organization>)"
  type        = string
}

variable "chainguard_pull_token_username" {
  description = "Identity ID from 'chainctl auth pull-token --repository=apk' (the Username field)"
  type        = string
}

variable "chainguard_pull_token_password" {
  description = "Token from 'chainctl auth pull-token --repository=apk' (the Password field)"
  type        = string
  sensitive   = true
}

variable "blob_store_name" {
  description = "Name of the Nexus blob store to use for all created repositories"
  type        = string
  default     = "default"
}

variable "index_max_age_minutes" {
  description = "Cache TTL for APKINDEX.tar.gz in minutes. Lower values give faster visibility of new packages at the cost of more origin fetches."
  type        = number
  default     = 15
}
