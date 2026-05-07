variable "chainguard_group_name" {
  description = "Chainguard parent group name (e.g. smalls.xyz). Must match CHAINGUARD_ORG used by the rest of the demo."
  type        = string
  default     = "smalls.xyz"
}

variable "jenkins_issuer_url" {
  description = "Issuer URL claim that Jenkins puts in OIDC tokens. Must be HTTPS (Chainguard provider validator) and must exactly match the iss claim Jenkins emits — which is jenkins.location.url + '/oidc'. The static block does offline JWKS verification, so the URL never has to resolve."
  type        = string
  default     = "https://localhost:8080/oidc"
}

variable "identity_expiration" {
  description = "RFC3339 timestamp at which the assumed identity stops accepting tokens. Must be in the future. Defaults to one year from a fixed-but-recent baseline; bump or rotate by running setup.sh again."
  type        = string
  default     = "2027-05-07T00:00:00Z"
}

variable "jenkins_subject" {
  description = "Subject claim that Jenkins puts in every OIDC token it issues to the cgr.dev credential. Configured in jenkins.yaml; must match here exactly."
  type        = string
  default     = "jenkins-cgimages-puller"
}
