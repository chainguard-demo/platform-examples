# jenkins/harbor — Optional Harbor pull-through cache

Stands up a [Harbor](https://goharbor.io/) registry in a local `kind` cluster, configured as a **pull-through cache** for `cgr.dev/${CHAINGUARD_ORG}/*`. Optionally also serves as a **push target** for the demo's OCI-image pipelines (Python and Node samples), replacing `ttl.sh`.

This directory is a lightly-adapted copy of [chainguard-demo/cs-workshop/.../harbor](https://github.com/chainguard-demo/cs-workshop/tree/main/trainer-development/operations-track/harbor) — the `deploy.sh` script is rewired to be env-var-driven (callable from `setup.sh`) and the Terraform module drops the replication-mirror project we don't need.

## When you'd want this

The default demo pulls Chainguard images directly from `cgr.dev/$CHAINGUARD_ORG` (using either a long-lived pull token or, on this branch, the OIDC assumed-identity flow). With Harbor in front:

- **Faster repeated pulls** — Harbor caches manifests and layers locally, so the second pull of `maven:3-jdk17-dev` is bytes-from-localhost.
- **Anonymous pulls from Jenkins** — the `cgr-proxy` project is public, so the controller doesn't need any cgr.dev credentials at runtime. Harbor itself still holds a pull token to authenticate to cgr.dev (the long-lived-secret problem moves from Jenkins to Harbor rather than disappearing).
- **A demo-able push target** — instead of pushing built images to `ttl.sh` (24h TTL, world-readable), pipelines can push to Harbor's `library` project where they persist.

## Architecture

```
                          ┌─ host ──────────────────────────────┐
                          │                                     │
                          │  kind cluster (jenkins-harbor)      │
   docker pull            │   ┌─────────────────────────────┐   │
   localhost/cgr-proxy/.. │   │  ingress-nginx :80          │   │
   ─────────────────────▶ │   │   ↓                         │   │
                          │   │  harbor-portal / -core      │   │
                          │   │   ↓                         │   │       cgr.dev
                          │   │  harbor-registry            │ ──┼──▶ (proxy-cache pull
                          │   │   ↑                         │   │     uses Harbor's
                          │   │  postgres / trivy / etc.    │   │     stored token)
                          │   └─────────────────────────────┘   │
                          │                                     │
                          └─────────────────────────────────────┘
```

Five Harbor microservices run in the `harbor` namespace plus ingress-nginx in `ingress-nginx`. Both pull from `cgr.dev/$CHAINGUARD_ORG` using a `regcred` docker-registry secret in each namespace. Harbor itself uses the same pull token to fetch from the upstream `cgr.dev` registry it's caching.

## Files

| Path | Purpose |
|------|---------|
| [`deploy.sh`](deploy.sh) | One-shot: brings up the kind cluster, installs ingress-nginx + Harbor Helm chart, runs Terraform. Idempotent. Driven by env vars. |
| [`teardown.sh`](teardown.sh) | `kind delete cluster --name jenkins-harbor`. |
| [`kind/config.yaml`](kind/config.yaml) | kind cluster definition with host port 80/443 mappings for ingress. |
| [`cg/helm/values.template`](cg/helm/values.template) | Harbor Helm values, parameterized on `${REGISTRY_URL}` so all images come from the configured Chainguard org. |
| [`cg/manifests/deploy-ingress-nginx.template`](cg/manifests/deploy-ingress-nginx.template) | ingress-nginx static manifest, parameterized on `${REGISTRY_URL}`. |
| [`terraform/main.tf`](terraform/main.tf) | After Harbor is up, this declares the cgr.dev upstream registry + the `cgr-proxy` proxy-cache project. |

## Direct invocation (for debugging)

The demo's top-level `setup.sh` calls `deploy.sh` automatically when you opt into Harbor mode. To run it by hand:

```sh
export CHAINGUARD_ORG=smalls.xyz
export PULL_USER=...    # chainctl auth pull-token create --parent=$CHAINGUARD_ORG
export PULL_PASS=...
./deploy.sh
```

The Harbor admin UI is at <https://localhost/harbor> (`admin` / `Harbor12345`). The chart issues a self-signed cert, so browsers will show a one-time warning — click through. Tear down with `./teardown.sh`.

> **Why HTTPS for the UI but HTTP for the registry?** Harbor 2.12.3+ ships with `gorilla/csrf` v1.7.3, which hardcodes the request scheme to `https` inside its origin check. Harbor's middleware doesn't compensate, so a plain-HTTP `POST /c/login` is rejected with `403 origin invalid` before the password is even checked (upstream bug: [goharbor/harbor#22010](https://github.com/goharbor/harbor/issues/22010)). The Docker daemon, in turn, refuses HTTPS connections to `127.0.0.0/8` by default, so the registry path (`/v2/`, `/service/token`, etc.) must remain reachable over HTTP. We split the two: TLS is enabled on the ingress for the UI, but `ssl-redirect` is off so HTTP isn't forced — the `externalURL` stays `http://localhost` so Harbor advertises HTTP to docker clients. Browser users type `https://`, pipelines push over `http://`, both work.
