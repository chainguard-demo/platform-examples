output "identity_uidp" {
  description = "UIDP of the Chainguard assumed identity. setup.sh writes this single-line value to ../shared-libraries/cg-images/IDENTITY, which cgLogin reads from the bind-mounted shared-libraries path on each pipeline build."
  value       = chainguard_identity.jenkins_puller.id
}
