# jenkins/iac — Chainguard assumed-identity Terraform module

Provisions the Chainguard IAM resources that let Jenkins authenticate to `cgr.dev` via OIDC token-exchange:

- A `chainguard_identity` named `jenkins-cgimages-puller`, configured with a `static` block that holds Jenkins' OIDC issuer URL, the fixed subject `jenkins-cgimages-puller`, and Jenkins' uploaded JWKS.
- A `chainguard_rolebinding` granting that identity `registry.pull` on the parent group.

## Why `static` instead of `claim_match`

The two are mutually exclusive. `claim_match` supports subject patterns but requires Chainguard's IAM to fetch JWKS from a public issuer URL — not viable for a local-Compose demo. `static` lets us upload the JWKS at apply time, so verification is fully offline. Cost: a single fixed subject (no per-build subject granularity in audit logs); benefit: no tunneling required.

## Usage

This module is driven by [../setup.sh](../setup.sh), not run by hand. The bootstrap flow is:

1. `docker compose up -d --build` — Jenkins starts and exposes its JWKS at `http://localhost:8080/oidc/jwks`.
2. `./setup.sh` — fetches that JWKS into `iac/jenkins-jwks.json`, runs `terraform apply`, captures the output `identity_uidp`, and writes it into `../.env` as `CHAINGUARD_IDENTITY=<uidp>`.
3. `docker compose restart jenkins` — picks up the new env var so pipelines have access to it.

Manual `terraform apply` works too (useful for debugging or org changes), but you must populate `jenkins-jwks.json` first.

## Variables

| Name | Default | What it controls |
|------|---------|------------------|
| `chainguard_group_name` | `smalls.xyz` | The parent group the identity lives under and the rolebinding's scope. |
| `jenkins_issuer_url` | `http://localhost:8080/oidc` | Must exactly match the `iss` claim Jenkins puts on its tokens. The `oidc-provider` plugin uses `<JENKINS_URL>/oidc` by default. |
| `jenkins_subject` | `jenkins-cgimages-puller` | Must exactly match the `sub` claim. Configured on the JCasC OIDC credential. |

## Reused conventions

- The resource pattern (`chainguard_identity` → `chainguard_rolebinding` to `registry.pull`) mirrors [../../image-copy-gcp/iac/main.tf](../../image-copy-gcp/iac/main.tf) — that module uses `claim_match` for Google's public OIDC; we use `static` for our local-only Jenkins.
