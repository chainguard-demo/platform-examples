output "identity_uidp" {
  description = "UIDP of the Chainguard assumed identity. setup.sh writes this into ../.env as CHAINGUARD_IDENTITY."
  value       = chainguard_identity.jenkins_puller.id
}
