# npm-native — migrating an npm lockfile to Chainguard Libraries

This repo demonstrates how to point an npm project at the Chainguard Libraries
registry (served via Artifactory) **without `chainctl`**, using two small scripts
that rely only on the Node and npm you already have.

- [`scripts/update-hashes.cjs`](scripts/update-hashes.cjs) — a dependency-free port
  of `chainctl libraries update-hashes`. Migrates a `package-lock.json` to a new
  registry.
- [`scripts/check-resolved.sh`](scripts/check-resolved.sh) — a `preinstall` guard
  that fails fast if the lockfile still points at a different registry than `.npmrc`.

## Background: why a lockfile doesn't migrate on its own

`npm ci` and `npm install` fetch each package from the **absolute `resolved` URL
pinned in `package-lock.json`** and verify the downloaded bytes against the
recorded `integrity`. Two consequences follow, both of which surprise people:

1. **Changing `registry=` in `.npmrc` does nothing to an existing lockfile.**
   npm keeps using the pinned `resolved` URLs, so you silently keep pulling from
   your old endpoint — a green build that never actually migrated.

2. **Rewriting `resolved` without updating `integrity` breaks the build.**
   Chainguard rebuilds packages from source, so a rebuilt version has *different
   bytes* (a different hash) than the upstream npm original of the same version.
   Point `resolved` at the Chainguard endpoint while keeping the old npm hash and
   you get:

   ```
   npm error code EINTEGRITY
   npm error ... integrity checksum failed ... wanted sha512-<npm> but got sha512-<chainguard>
   ```

So a migration must change **`resolved` and `integrity` together**. That is
exactly what `update-hashes.cjs` does.

> Note: not every version is rebuilt. Versions Chainguard serves as upstream
> passthrough have an identical hash and need no change; only rebuilt versions
> diverge. The script figures this out per package from the registry.

## `scripts/update-hashes.cjs`

Rewrites every registry-resolved package in a `package-lock.json` so that
`resolved` points at the target registry and `integrity` matches what that
registry serves.

By default it **appends** the new hash to the existing one. npm's `integrity`
field is [SRI](https://www.w3.org/TR/SRI/) and accepts multiple space-separated
hashes — a tarball validates if it matches *any* of them. Keeping both the
upstream and Chainguard hashes means the lockfile validates whether a given
environment fetches the old bytes or the new ones, so a rollout never breaks.
Use `--replace` for a hard cutover to the Chainguard hash only.

### Usage

Registry and auth are inherited from `.npmrc` (the script reads the file directly
and expands `${ENV}` tokens), so the common case is just:

```bash
node scripts/update-hashes.cjs
rm -rf node_modules && npm ci        # pull the Chainguard-built packages
```

Options:

| Flag | Meaning |
|---|---|
| `--registry-url <url>` | Target registry (default: `npm config get registry`) |
| `--token <token>` | Bearer token (default: `_authToken` from `.npmrc`) |
| `--username <u> --password <p>` | Use HTTP Basic auth instead |
| `--replace` | Replace integrity with the Chainguard hash only (hard cutover) |
| `--dry-run` | Print the summary, write nothing |
| `-h`, `--help` | Show help |

Positional arg is the lockfile path (default `package-lock.json`).

Example matching the `chainctl` invocation:

```bash
node scripts/update-hashes.cjs package-lock.json \
  --registry-url https://<host>/artifactory/api/npm/<repo> \
  --username <user> --password <token>
```

Supports lockfile v2 (`dependencies` tree) and v3 (`packages` map), scoped
packages, and reports `total / updated / already current / failed`.

## `scripts/check-resolved.sh`

A guard that fails (exit 1) if any registry tarball in `package-lock.json`
resolves from a registry other than the one configured in `.npmrc`. It catches
the "green but never migrated" state.

It **verifies, it does not rewrite** — auto-rewriting `resolved` without fixing
`integrity` would reintroduce EINTEGRITY. On failure it tells you to run
`update-hashes`.

Wired as a `preinstall` script in `package.json`, so it runs on every
`npm install` and `npm ci`:

```json
"scripts": {
  "preinstall": "bash scripts/check-resolved.sh",
  "check-resolved": "bash scripts/check-resolved.sh"
}
```

Run it directly anytime:

```bash
npm run check-resolved
```

> `preinstall` is skipped when npm runs with `--ignore-scripts`. For a
> hard guarantee, also run `npm run check-resolved` as an explicit CI step.

## End-to-end migration

```bash
# 1. Point .npmrc at the Chainguard registry (+ auth token)
# 2. Migrate the lockfile's resolved + integrity
node scripts/update-hashes.cjs
# 3. Install the Chainguard-built packages
rm -rf node_modules && npm ci
```

## Security note

Do not commit a plaintext token in `.npmrc`. Use an env var reference instead:

```
//<host>/artifactory/api/npm/<repo>/:_authToken=${NPM_TOKEN}
```

and `export NPM_TOKEN=...` before running npm or the scripts.
