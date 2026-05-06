#!/usr/bin/env bash
# One-time setup: generate a Chainguard pull token for the smalls.xyz org and
# write a Docker config.json that the Jenkins container will use to pull
# cgr.dev/smalls.xyz/* images. Re-run when the token expires.
set -euo pipefail

cd "$(dirname "$0")"

ORG="${CHAINGUARD_ORG:-smalls.xyz}"
TOKEN_NAME="${TOKEN_NAME:-jenkins-demo}"
TTL="${TTL:-720h}"
OUT_DIR="$(pwd)/.secrets"
OUT_FILE="${OUT_DIR}/docker-config.json"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

echo "Creating pull token (parent=${ORG}, ttl=${TTL})..."
TOKEN_OUTPUT=$(chainctl auth pull-token create \
  --parent="$ORG" \
  --name="$TOKEN_NAME" \
  --ttl="$TTL")

# The output contains: docker login "cgr.dev" --username "<user>" --password "<jwt>"
USERNAME=$(echo "$TOKEN_OUTPUT" | grep -oE -- '--username "[^"]+"' | head -1 | sed -E 's/--username "([^"]+)"/\1/')
PASSWORD=$(echo "$TOKEN_OUTPUT" | grep -oE -- '--password "[^"]+"' | head -1 | sed -E 's/--password "([^"]+)"/\1/')

if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
  echo "ERROR: failed to parse token from chainctl output:" >&2
  echo "$TOKEN_OUTPUT" >&2
  exit 1
fi

AUTH_B64=$(printf '%s:%s' "$USERNAME" "$PASSWORD" | base64 | tr -d '\n')

cat > "$OUT_FILE" <<EOF
{
  "auths": {
    "cgr.dev": {
      "auth": "${AUTH_B64}"
    }
  }
}
EOF
chmod 600 "$OUT_FILE"

echo "Wrote ${OUT_FILE}"
echo "Now run: docker compose up -d --build"
