#!/usr/bin/env bash
# Re-resolve every image reference in vars/cgImage.groovy to its current digest,
# rewriting in place. Run this when:
#   - You want to pick up newer image versions (security patches, etc.)
#   - You added a new entry without a digest and want it pinned
#
# Requires: crane (https://github.com/google/go-containerregistry).
# Picks up CHAINGUARD_ORG from ../../.env so the digests match the org the
# rest of the demo is configured for.
set -euo pipefail

cd "$(dirname "$0")"

if [[ -z "${CHAINGUARD_ORG:-}" && -f ../../.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ../../.env
  set +a
fi
if [[ -z "${CHAINGUARD_ORG:-}" ]]; then
  echo "ERROR: CHAINGUARD_ORG must be set (in env or in ../../.env)." >&2
  exit 1
fi
ORG="$CHAINGUARD_ORG"

# Route digest lookups through PULL_REGISTRY rather than cgr.dev directly:
# in Mode A that's still cgr.dev/<org> (using whatever docker auth is in
# DOCKER_CONFIG), but in Modes B/C it's the anonymous Harbor proxy at
# localhost/cgr-proxy/<org>, which sidesteps the need for cgr.dev creds in
# the crane agent. Either way the manifest digest crane returns is the
# same — Harbor proxy serves the upstream manifest verbatim.
REGISTRY="${PULL_REGISTRY:-cgr.dev/${ORG}}"
# crane uses go-containerregistry, whose reference parser rejects bare
# 'localhost' as a registry hostname (treats it as a Docker Hub path
# component) and falls back to index.docker.io. The fix is the same one
# we apply in cgSign / cgVerify: rewrite 'localhost/...' to 'localhost:80/...'
# so the parser sees a host:port and recognises localhost as the registry.
case "$REGISTRY" in
  localhost/*) REGISTRY="localhost:80/${REGISTRY#localhost/}" ;;
esac

CATALOG=vars/cgImage.groovy
echo "Refreshing digests in ${CATALOG} against ${REGISTRY}/..."

# Extract every single-quoted "<repo>:<tag>" or "<repo>:<tag>@sha256:..." entry
# from the catalog, strip the digest suffix so multiple stale-digest entries
# collapse to one crane call, and dedupe with `sort -u`. We avoid bash-4
# constructs (`mapfile`, `declare -A`) so this script also works on macOS's
# default /bin/bash 3.2.
reftags_file=$(mktemp)
trap 'rm -f "$reftags_file"' EXIT

grep -oE "'[a-z][a-z0-9_.-]*:[a-zA-Z0-9._-]+(@sha256:[0-9a-f]{64})?'" "$CATALOG" \
  | tr -d "'" \
  | sed -E 's/@sha256:[0-9a-f]{64}$//' \
  | sort -u \
  > "$reftags_file"

if [[ ! -s "$reftags_file" ]]; then
  echo "No image references found in ${CATALOG}." >&2
  exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$reftags_file" "$tmp"' EXIT
cp "$CATALOG" "$tmp"

while IFS= read -r reftag; do
  printf '  %-50s ' "$reftag"
  digest=$(crane digest "${REGISTRY}/${reftag}")
  echo "$digest"
  pinned="${reftag}@${digest}"

  # Replace any existing pinned form of this reftag (with any old digest) and
  # any unpinned form, with the new pinned form. Use sed rather than perl
  # because perl interpolates `@sha256` as an array variable in the
  # replacement, eating the @ sign.
  sed -i.bak -E "s|'${reftag}(@sha256:[0-9a-f]{64})?'|'${pinned}'|g" "$tmp"
  rm -f "${tmp}.bak"
done < "$reftags_file"

mv "$tmp" "$CATALOG"
rm -f "$reftags_file"
trap - EXIT
echo
# Show a diff if git is available and we're inside a checkout (e.g. running
# from a developer's laptop); silently skip otherwise (e.g. inside the crane
# container the Jenkins job runs in, which has no git).
if command -v git >/dev/null 2>&1 && git -C "$(dirname "$CATALOG")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Done. Diff:"
  git --no-pager diff -- "$CATALOG" || true
else
  echo "Done."
fi
