#!/usr/bin/env node
/*
 * update-hashes.js — a dependency-free, chainctl-free port of
 * `chainctl libraries update-hashes` for npm lockfiles.
 *
 * It rewrites every registry-resolved package in a package-lock.json so that:
 *   1. `resolved` points at the target registry (e.g. your Chainguard endpoint), and
 *   2. `integrity` carries the hash that registry actually serves.
 *
 * Why both must change together: `npm ci`/`npm install` fetch the absolute
 * `resolved` URL from the lockfile and verify the bytes against `integrity`.
 * Repointing the registry in .npmrc alone does nothing (npm keeps using the
 * pinned `resolved`); repointing `resolved` without fixing `integrity` yields
 * EINTEGRITY once the new endpoint serves rebuilt bytes.
 *
 * By default it APPENDS the new hash to any existing ones (valid multi-hash SRI),
 * so the lockfile validates against both the old and new bytes during a rollout.
 * Use --replace to write only the new hash (hard cutover, Chainguard-only).
 *
 * Config is inherited from .npmrc via `npm config`, so in the common case you
 * just run:  node scripts/update-hashes.js
 *
 * Usage:
 *   node scripts/update-hashes.js [package-lock.json] [options]
 * Options:
 *   --registry-url <url>   Target registry (default: `npm config get registry`)
 *   --token <token>        Bearer token (default: _authToken from .npmrc)
 *   --username <user>      With --password, use HTTP Basic auth instead
 *   --password <pass>      Password/token for Basic auth
 *   --replace              Replace integrity instead of appending the new hash
 *   --dry-run              Print the diff summary, do not write the file
 *   -h, --help             Show this help
 */
'use strict';

const fs = require('fs');
const https = require('https');
const http = require('http');
const { execFileSync } = require('child_process');
const { URL } = require('url');

// ---- arg parsing ----------------------------------------------------------
const argv = process.argv.slice(2);
const opts = { replace: false, dryRun: false };
let lockPath = 'package-lock.json';
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--replace') opts.replace = true;
  else if (a === '--dry-run') opts.dryRun = true;
  else if (a === '-h' || a === '--help') { printHelpAndExit(); }
  else if (a === '--registry-url') opts.registry = argv[++i];
  else if (a === '--token') opts.token = argv[++i];
  else if (a === '--username') opts.username = argv[++i];
  else if (a === '--password') opts.password = argv[++i];
  else if (!a.startsWith('-')) lockPath = a;
  else { console.error(`Unknown option: ${a}`); process.exit(2); }
}

function printHelpAndExit() {
  console.log(fs.readFileSync(__filename, 'utf8').split('*/')[0].replace(/^\/\*|^ \*?/gm, '').trim());
  process.exit(0);
}

const os = require('os');
const path = require('path');

function npmConfig(key) {
  try {
    return execFileSync('npm', ['config', 'get', key], { encoding: 'utf8' }).trim();
  } catch { return ''; }
}

// Parse .npmrc files (user then project; project wins) into a key=value map,
// expanding ${ENV} references the way npm does. npm blocks `npm config get`
// from returning `_authToken`, so we read the files ourselves.
function loadNpmrc() {
  const files = [
    process.env.npm_config_userconfig || path.join(os.homedir(), '.npmrc'),
    path.join(process.cwd(), '.npmrc'),
  ];
  const map = {};
  for (const f of files) {
    let text;
    try { text = fs.readFileSync(f, 'utf8'); } catch { continue; }
    for (const line of text.split('\n')) {
      const s = line.trim();
      if (!s || s.startsWith('#') || s.startsWith(';')) continue;
      const eq = s.indexOf('=');
      if (eq === -1) continue;
      const k = s.slice(0, eq).trim();
      let v = s.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
      v = v.replace(/\$\{([^}]+)\}/g, (_, name) => process.env[name] || '');
      map[k] = v;
    }
  }
  return map;
}

// Find auth for a registry, matching npm's longest-prefix nerf-dart lookup.
function authFromNpmrc(regUrl) {
  const rc = loadNpmrc();
  const segs = regUrl.pathname.replace(/\/+$/, '').split('/');
  for (let i = segs.length; i >= 1; i--) {
    const p = segs.slice(0, i).join('/');
    for (const base of [`//${regUrl.host}${p}/`, `//${regUrl.host}${p}`]) {
      if (rc[`${base}:_authToken`]) return 'Bearer ' + rc[`${base}:_authToken`];
      if (rc[`${base}:_auth`]) return 'Basic ' + rc[`${base}:_auth`];
      if (rc[`${base}:username`] && rc[`${base}:_password`]) {
        const pw = Buffer.from(rc[`${base}:_password`], 'base64').toString('utf8');
        return 'Basic ' + Buffer.from(`${rc[`${base}:username`]}:${pw}`).toString('base64');
      }
    }
  }
  return '';
}

// ---- resolve registry + auth from flags, else .npmrc ----------------------
let registry = (opts.registry || npmConfig('registry') || '').replace(/\/+$/, '');
if (!registry || registry === 'undefined' || registry === 'null') {
  console.error('No registry configured. Pass --registry-url or set one in .npmrc.');
  process.exit(2);
}
const registryUrl = new URL(registry + '/');

// Auth precedence: --username/--password (Basic) > --token (Bearer) > .npmrc.
let authHeader = '';
if (opts.username && opts.password) {
  authHeader = 'Basic ' + Buffer.from(`${opts.username}:${opts.password}`).toString('base64');
} else if (opts.token) {
  authHeader = 'Bearer ' + opts.token;
} else {
  authHeader = authFromNpmrc(registryUrl);
}

// ---- helpers --------------------------------------------------------------
function get(urlStr) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlStr);
    const lib = u.protocol === 'http:' ? http : https;
    const headers = { accept: 'application/json' };
    if (authHeader) headers.authorization = authHeader;
    lib.get(u, { headers }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        return resolve(get(new URL(res.headers.location, u).toString()));
      }
      let data = '';
      res.on('data', (d) => (data += d));
      res.on('end', () => {
        if (res.statusCode !== 200) return reject(new Error(`HTTP ${res.statusCode} for ${urlStr}`));
        resolve(data);
      });
    }).on('error', reject);
  });
}

const packumentCache = new Map();
async function getIntegrity(name, version) {
  if (!packumentCache.has(name)) {
    // Artifactory/npm serve the packument at <registry>/<name> (scope slash kept).
    const url = registry + '/' + name.replace('/', '%2F');
    packumentCache.set(name, JSON.parse(await get(url)));
  }
  const pack = packumentCache.get(name);
  const v = pack.versions && pack.versions[version];
  if (!v || !v.dist || !v.dist.integrity) {
    throw new Error(`no integrity for ${name}@${version} at ${registry}`);
  }
  return v.dist.integrity;
}

function unscoped(name) { return name.includes('/') ? name.split('/').pop() : name; }

function newResolvedFor(name, version) {
  return `${registry}/${name}/-/${unscoped(name)}-${version}.tgz`;
}

function mergeIntegrity(existing, fresh, replace) {
  if (replace || !existing) return fresh;
  const parts = existing.split(/\s+/).filter(Boolean);
  if (!parts.includes(fresh)) parts.push(fresh);
  return parts.join(' ');
}

// ---- main -----------------------------------------------------------------
(async () => {
  if (!fs.existsSync(lockPath)) {
    console.error(`No ${lockPath} found.`);
    process.exit(2);
  }
  const raw = fs.readFileSync(lockPath, 'utf8');
  const lock = JSON.parse(raw);

  // Collect every entry with a registry tarball `resolved`, from both the v3
  // `packages` map and the legacy v2 `dependencies` tree.
  const targets = [];
  for (const [key, meta] of Object.entries(lock.packages || {})) {
    if (!meta || typeof meta.resolved !== 'string') continue;
    if (!/^https?:\/\//.test(meta.resolved) || !meta.resolved.includes('/-/')) continue;
    const name = key.replace(/^.*node_modules\//, '');
    if (!name || !meta.version) continue;
    targets.push({ meta, name, version: meta.version });
  }
  (function walkDeps(deps) {
    for (const [name, meta] of Object.entries(deps || {})) {
      if (meta && typeof meta.resolved === 'string' && /^https?:\/\//.test(meta.resolved)
          && meta.resolved.includes('/-/') && meta.version) {
        targets.push({ meta, name, version: meta.version });
      }
      if (meta && meta.dependencies) walkDeps(meta.dependencies);
    }
  })(lock.dependencies);

  let updated = 0, current = 0;
  const failures = [];
  for (const t of targets) {
    try {
      const fresh = await getIntegrity(t.name, t.version);
      const newResolved = newResolvedFor(t.name, t.version);
      const newIntegrity = mergeIntegrity(t.meta.integrity, fresh, opts.replace);
      const changed = t.meta.resolved !== newResolved || t.meta.integrity !== newIntegrity;
      if (changed) {
        t.meta.resolved = newResolved;
        t.meta.integrity = newIntegrity;
        updated++;
        console.log(`  ~ ${t.name}@${t.version}`);
      } else {
        current++;
      }
    } catch (e) {
      failures.push(`${t.name}@${t.version}: ${e.message}`);
    }
  }

  console.log(`\nFormat: npm`);
  console.log(`Packages: ${targets.length} total, ${updated} updated, ${current} already current, ${failures.length} failed`);
  if (failures.length) {
    console.error('\nFailures:');
    for (const f of failures) console.error('  - ' + f);
  }

  if (opts.dryRun) {
    console.log('\n(dry run — no changes written)');
  } else if (updated) {
    fs.writeFileSync(lockPath, JSON.stringify(lock, null, 2) + '\n');
    console.log(`\nWrote ${lockPath}. Next: rm -rf node_modules && npm install`);
  }
  process.exit(failures.length ? 1 : 0);
})().catch((e) => { console.error(e.message); process.exit(1); });
