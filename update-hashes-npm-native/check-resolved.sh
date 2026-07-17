#!/usr/bin/env bash
#
# check-resolved.sh — fail fast if package-lock.json resolves packages from a
# registry other than the one configured in .npmrc.
#
# Why: `npm ci`/`npm install` fetch each package from the absolute `resolved`
# URL pinned in the lockfile and ignore the `registry=` in .npmrc for packages
# that are already locked. So after switching registries, a lockfile that still
# points at the old endpoint will silently keep pulling from it (no migration),
# or blow up with EINTEGRITY once the new endpoint serves different bytes.
#
# This is a CHECK, not a fixer. It deliberately does not rewrite `resolved`,
# because rewriting the URL without also updating `integrity` reintroduces the
# EINTEGRITY mismatch. When it fails, run `chainctl libraries update-hashes`
# (or `rm package-lock.json && npm install`) to migrate both fields together.
#
# Usage:   bash scripts/check-resolved.sh [path/to/package-lock.json]
# Wire it: add  "preinstall": "bash scripts/check-resolved.sh"  to package.json.
set -euo pipefail

LOCKFILE="${1:-package-lock.json}"

if [ ! -f "$LOCKFILE" ]; then
  echo "check-resolved: no $LOCKFILE (nothing locked yet) — skipping"
  exit 0
fi

# Expected registry base from npm's resolved config (honors .npmrc / env / flags).
EXPECTED="$(npm config get registry 2>/dev/null || true)"
EXPECTED="${EXPECTED%/}"
if [ -z "$EXPECTED" ] || [ "$EXPECTED" = "undefined" ] || [ "$EXPECTED" = "null" ]; then
  echo "check-resolved: no registry configured — skipping"
  exit 0
fi

LOCKFILE="$LOCKFILE" EXPECTED="$EXPECTED" node <<'NODE'
const fs = require('fs');
const lockPath = process.env.LOCKFILE;
const expected = process.env.EXPECTED;

const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
const pkgs = lock.packages || {};
const bad = [];

for (const [name, meta] of Object.entries(pkgs)) {
  const r = meta && meta.resolved;
  if (!r || typeof r !== 'string') continue;   // root/workspace/link entries
  if (!/^https?:\/\//.test(r)) continue;        // git/file/tarball deps — leave alone
  if (!r.includes('/-/')) continue;             // not a registry tarball layout
  if (!r.startsWith(expected + '/')) bad.push([name || '(root)', r]);
}

if (bad.length) {
  console.error(`\n✖ ${bad.length} package(s) in ${lockPath} resolve from a different registry than .npmrc:`);
  console.error(`  configured registry: ${expected}/`);
  for (const [n, r] of bad) console.error(`  - ${n}\n      ${r}`);
  console.error(`\nThe lockfile still points at another endpoint. Migrate resolved + integrity together:`);
  console.error(`  chainctl libraries update-hashes ${lockPath} --registry-url ${expected} --username <user> --password <token>`);
  console.error(`  # or, to re-resolve from scratch:  rm ${lockPath} && npm install\n`);
  process.exit(1);
}

console.log(`✓ check-resolved: all registry packages match ${expected}`);
NODE
