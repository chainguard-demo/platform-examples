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
ORG="${CHAINGUARD_ORG:-smalls.xyz}"

CATALOG=vars/cgImage.groovy
echo "Refreshing digests in ${CATALOG} against cgr.dev/${ORG}/..."

# Extract every single-quoted "<repo>:<tag>" or "<repo>:<tag>@sha256:..." entry
# from the catalog. We deduplicate by the repo:tag portion (everything before
# the optional @ digest) so multiple stale-digest entries collapse to one
# crane call.
mapfile -t pairs < <(
  grep -oE "'[a-z][a-z0-9_.-]*:[a-zA-Z0-9._-]+(@sha256:[0-9a-f]{64})?'" "$CATALOG" \
    | tr -d "'" \
    | sort -u
)

if (( ${#pairs[@]} == 0 )); then
  echo "No image references found in ${CATALOG}." >&2
  exit 1
fi

# Build the unique set of repo:tag values to query.
declare -A reftags
for entry in "${pairs[@]}"; do
  reftag="${entry%@*}"
  reftags["$reftag"]=1
done

tmp=$(mktemp)
cp "$CATALOG" "$tmp"

for reftag in "${!reftags[@]}"; do
  printf '  %-50s ' "$reftag"
  digest=$(crane digest "cgr.dev/${ORG}/${reftag}")
  echo "$digest"
  pinned="${reftag}@${digest}"

  # Replace any existing pinned form of this reftag (with any old digest) and
  # any unpinned form, with the new pinned form. Use sed rather than perl
  # because perl interpolates `@sha256` as an array variable in the
  # replacement, eating the @ sign.
  sed -i.bak -E "s|'${reftag}(@sha256:[0-9a-f]{64})?'|'${pinned}'|g" "$tmp"
  rm -f "${tmp}.bak"
done

mv "$tmp" "$CATALOG"
echo
echo "Done. Diff:"
git --no-pager diff -- "$CATALOG" || true
