# node25-pnpm-express

Hello-world Express web app on Chainguard's Node 25, with `pnpm` as the package manager and `node:25-slim` as the runtime variant. Pipeline artifact is an OCI image pushed to `ttl.sh/smalls-nodetest:25`.

> Image references below show the default org (`smalls.xyz`); see the demo's top-level [README](../../README.md#configuration) for how to switch.

## Pipeline images

| Stage       | Image |
|-------------|-------|
| Build deps  | `cgr.dev/smalls.xyz/node:25-dev` (ships pnpm 10.33) |
| Image build | host docker daemon (multi-stage build) |
| Test        | runs the just-built image |
| Push        | `ttl.sh/smalls-nodetest:25` |

## Why pnpm + slim?

- **pnpm**: alternative package manager that uses a content-addressable store and symlinks. `pnpm install --prod --frozen-lockfile` installs only production deps and fails fast if `pnpm-lock.yaml` is out of sync with `package.json` — useful for CI reproducibility.
- **slim**: PLAN.md called for the `node:25-slim` variant for the runtime layer. Same shell-less runtime as the regular tag but on a smaller base image.

## npm libraries used

- `express` (web server)
- `nanoid` (cryptographically random ID — used to generate a per-instance ID shown in the rendered HTML, satisfying PLAN.md's "include some kind of npm library" requirement)

## Smoke test

Same in-process self-request pattern as the Node 22 sibling — runs the runtime image with `--entrypoint=/usr/bin/node` and an inline `-e` script that boots the app on an ephemeral loopback port and asserts the rendered greeting.

## Pull and run

```sh
docker pull ttl.sh/smalls-nodetest:25
docker run --rm -p 8080:8080 ttl.sh/smalls-nodetest:25
# Visit http://localhost:8080/
```

ttl.sh tags expire (default 24 hours). Re-run the pipeline to refresh.
