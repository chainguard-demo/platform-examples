# node25-pnpm-express

Hello-world Express web app on Chainguard's Node 25, with `pnpm` as the package manager and `node:25-slim` as the runtime variant. Pipeline artifact is an OCI image pushed to `$PUSH_REGISTRY/nodetest:25`.

> `$CHAINGUARD_ORG` below stands in for your configured Chainguard org — see the top-level [README](../../README.md#configuration) for how that gets set.

## Pipeline images

| Stage       | Image |
|-------------|-------|
| Build deps  | `cgr.dev/$CHAINGUARD_ORG/node:25-dev` (ships pnpm 10.33) |
| Image build | host docker daemon (multi-stage build) |
| Test        | runs the just-built image |
| Push        | `$PUSH_REGISTRY/nodetest:25` |

## Why pnpm + slim?

- **pnpm**: alternative package manager that uses a content-addressable store and symlinks. `pnpm install --prod --frozen-lockfile` installs only production deps and fails fast if `pnpm-lock.yaml` is out of sync with `package.json` — useful for CI reproducibility.
- **slim**: the `node:25-slim` runtime variant — same shell-less runtime as the regular tag, on a smaller base image. Pairs well with pnpm's leaner `node_modules` to keep the final OCI image compact.

## npm libraries used

- `express` (web server)
- `nanoid` (cryptographically random ID — used to generate a per-instance ID shown in the rendered HTML; demonstrates a real npm dep going through pnpm install)

## Smoke test

Same in-process self-request pattern as the Node 22 sibling — runs the runtime image with `--entrypoint=/usr/bin/node` and an inline `-e` script that boots the app on an ephemeral loopback port and asserts the rendered greeting.

## Pull and run

```sh
docker pull $PUSH_REGISTRY/nodetest:25
docker run --rm -p 8080:8080 $PUSH_REGISTRY/nodetest:25
# Visit http://localhost:8080/
```

If `$PUSH_REGISTRY` points at ttl.sh (Modes A/B), tags expire after the default 24 hours — re-run the pipeline to refresh. In Mode C the push goes to the local Harbor (`localhost/library/...`) and persists until teardown.
