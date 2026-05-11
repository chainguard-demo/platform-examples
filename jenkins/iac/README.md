# jenkins/iac — Chainguard assumed-identity Terraform module

Provisions the Chainguard IAM resources that let Jenkins authenticate to `cgr.dev` via OIDC token-exchange:

- A `chainguard_identity` named `jenkins-cgimages-puller`, configured with a `static` block that holds Jenkins' OIDC issuer URL, the fixed subject `jenkins-cgimages-puller`, and Jenkins' uploaded JWKS.
- A `chainguard_rolebinding` granting that identity `registry.pull` on the parent group.

## Why `static` instead of `claim_match`

The two are mutually exclusive. `claim_match` supports subject patterns but requires Chainguard's IAM to fetch JWKS from a public issuer URL — not viable for a local-Compose demo. `static` lets us upload the JWKS at apply time, so verification is fully offline. Cost: a single fixed subject (no per-build subject granularity in audit logs); benefit: no tunneling required.

## Usage

This module is driven by [../setup.sh](../setup.sh), not run by hand. The bootstrap flow is:

1. `./setup.sh` — brings Jenkins up via `docker compose`, waits for `http://localhost:8080/oidc/jwks` to respond, fetches that JWKS into `iac/jenkins-jwks.json`, runs `terraform apply`, captures the output `identity_uidp`, and writes it to `../shared-libraries/cg-images/IDENTITY` (a single line, just the UIDP).
2. Jenkins picks up the identity at pipeline-build time. The shared library `cgLogin()` reads the IDENTITY file directly from the bind-mounted filesystem path on every build — no controller restart is needed.

Manual `terraform apply` works too (useful for debugging or org changes), but you must populate `jenkins-jwks.json` first.

## Variables

| Name | Default | What it controls |
|------|---------|------------------|
| `chainguard_group_name` | *(required, no default)* | The parent group the identity lives under and the rolebinding's scope. setup.sh passes this via `-var` from `.env`'s `CHAINGUARD_ORG`. |
| `jenkins_issuer_url` | `https://localhost:8080/oidc` | Must exactly match the `iss` claim Jenkins puts on its tokens. The `oidc-provider` plugin uses `<JENKINS_URL>/oidc`. HTTPS is required by the Chainguard Terraform provider's validator even though the local Jenkins listens on plain HTTP — the URL is never fetched (the `static` block does offline JWKS verification), so the scheme is purely a claim-match string. The JCasC config (`jenkins/casc/jenkins.yaml`) sets `unsafe.jenkins.JenkinsLocationConfiguration.url` to `https://localhost:8080/` so Jenkins emits `iss=https://localhost:8080/oidc` to match. |
| `jenkins_subject` | `jenkins-cgimages-puller` | Must exactly match the `sub` claim. Configured on the JCasC OIDC credential. |

## Reused conventions

- The resource pattern (`chainguard_identity` → `chainguard_rolebinding` to `registry.pull`) mirrors [../../image-copy-gcp/iac/main.tf](../../image-copy-gcp/iac/main.tf) — that module uses `claim_match` for Google's public OIDC; we use `static` for our local-only Jenkins.
