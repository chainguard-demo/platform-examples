locals {
  remote_url = "https://apk.cgr.dev/${var.chainguard_organization}"
}

# Split APKINDEX requests from package requests so each proxy can use its own
# cache TTL. The block rule goes on the packages proxy; the allow rule goes on
# the index proxy. Both reference the same regex.

resource "sonatyperepo_routing_rule" "block_index" {
  name        = "tf-chainguard-apk-block-index"
  description = "Block APKINDEX.tar.gz paths from the packages proxy."
  mode        = "BLOCK"
  matchers    = [".*APKINDEX\\.tar\\.gz"]
}

resource "sonatyperepo_routing_rule" "only_index" {
  name        = "tf-chainguard-apk-only-index"
  description = "Restrict the index proxy to APKINDEX.tar.gz paths only."
  mode        = "ALLOW"
  matchers    = [".*APKINDEX\\.tar\\.gz"]
}

# Packages proxy — handles .apk file requests.
# Packages are immutable, so content_max_age = -1 (never re-check the origin).
#
# MANUAL STEP REQUIRED: After applying, open this repository in the Nexus UI
# (Settings → Repository → Repositories → chainguard-apk-packages) and enable
# "Preserve encoded characters in URLs" under the HTTP section. This is not yet
# exposed by the Terraform provider. Without it, Nexus decodes percent-encoded
# characters (%2B, %2F, %3D) in the presigned R2 URLs that apk.cgr.dev
# redirects to, breaking the request signature.
resource "sonatyperepo_repository_raw_proxy" "packages" {
  name         = "tf-chainguard-apk-packages"
  online       = true
  routing_rule = sonatyperepo_routing_rule.block_index.name

  storage = {
    blob_store_name                = var.blob_store_name
    strict_content_type_validation = false
  }

  proxy = {
    remote_url       = local.remote_url
    content_max_age  = -1
    metadata_max_age = -1
  }

  negative_cache = {
    enabled      = true
    time_to_live = 1440
  }

  http_client = {
    blocked    = false
    auto_block = true
    authentication = {
      type     = "username"
      username = var.chainguard_pull_token_username
      password = var.chainguard_pull_token_password
    }
  }

  raw = {
    content_disposition = "ATTACHMENT"
  }
}

# Index proxy — handles APKINDEX.tar.gz requests.
# The index is regenerated upstream whenever a package is added, so a short TTL
# is used. Tune index_max_age_minutes up to reduce origin fetches, down for
# faster visibility of newly published packages.
#
# MANUAL STEP REQUIRED: Same as above — enable "Preserve encoded characters in
# URLs" for chainguard-apk-index in the Nexus UI after applying.
resource "sonatyperepo_repository_raw_proxy" "index" {
  name         = "tf-chainguard-apk-index"
  online       = true
  routing_rule = sonatyperepo_routing_rule.only_index.name

  storage = {
    blob_store_name                = var.blob_store_name
    strict_content_type_validation = false
  }

  proxy = {
    remote_url       = local.remote_url
    content_max_age  = var.index_max_age_minutes
    metadata_max_age = var.index_max_age_minutes
  }

  negative_cache = {
    enabled      = true
    time_to_live = 1440
  }

  http_client = {
    blocked    = false
    auto_block = true
    authentication = {
      type     = "username"
      username = var.chainguard_pull_token_username
      password = var.chainguard_pull_token_password
    }
  }

  raw = {
    content_disposition = "ATTACHMENT"
  }
}

# Group repository — the single URL clients point apk at.
# Packages proxy is listed first so its routing rule (BLOCK on APKINDEX) fires
# before the request falls through to the index proxy.
resource "sonatyperepo_repository_raw_group" "group" {
  name   = "tf-chainguard-apk"
  online = true

  storage = {
    blob_store_name                = var.blob_store_name
    strict_content_type_validation = false
  }

  group = {
    member_names = [
      sonatyperepo_repository_raw_proxy.packages.name,
      sonatyperepo_repository_raw_proxy.index.name,
    ]
  }

  raw = {
    content_disposition = "ATTACHMENT"
  }
}
