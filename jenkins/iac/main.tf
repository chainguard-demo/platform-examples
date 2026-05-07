terraform {
  required_providers {
    chainguard = {
      source  = "chainguard-dev/chainguard"
      version = "~> 0.2"
    }
  }
}

provider "chainguard" {}

# Resolve the parent group (the same group that owns the smalls.xyz catalog).
data "chainguard_group" "parent" {
  name = var.chainguard_group_name
}

# Look up the registry.pull role.
data "chainguard_role" "puller" {
  name = "registry.pull"
}

# Identity that Jenkins assumes via OIDC token-exchange. Uses a `static`
# block so we upload Jenkins' JWKS at apply time — Chainguard's IAM never
# needs to fetch it from the controller (which is local-only, not publicly
# reachable). All builds present an OIDC token with subject jenkins_subject;
# the Jenkins oidc-provider plugin is configured in jenkins.yaml to set
# exactly that subject on every token it issues.
resource "chainguard_identity" "jenkins_puller" {
  parent_id = data.chainguard_group.parent.id
  name      = "jenkins-cgimages-puller"
  description = "Jenkins assumes this identity via OIDC token exchange to pull cgImages catalog images. JWKS uploaded statically; no public reachability required."

  static {
    issuer      = var.jenkins_issuer_url
    subject     = var.jenkins_subject
    issuer_keys = file("${path.module}/jenkins-jwks.json")
    expiration  = var.identity_expiration
  }
}

# Grant the identity registry.pull on the parent group so it can pull any
# cgr.dev/<group>/<image>:<tag> covered by the cgImages catalog.
resource "chainguard_rolebinding" "jenkins_puller_pulls" {
  identity = chainguard_identity.jenkins_puller.id
  group    = data.chainguard_group.parent.id
  role     = data.chainguard_role.puller.items[0].id
}
