#!/usr/bin/env bash
# Interactive bootstrap. Asks the user three questions about how Jenkins
# should pull and push images, then sets up:
#
#   Mode A — direct cgr.dev (no Harbor)
#       PULL: cgr.dev/$CHAINGUARD_ORG (per-build OIDC chainctl session)
#       PUSH: ttl.sh/<prefix>      (anonymous, default; user can override)
#
#   Mode B — Harbor for pulls, push elsewhere
#       PULL: localhost/cgr-proxy/$CHAINGUARD_ORG (anonymous, Harbor pull-through)
#       PUSH: ttl.sh/<prefix>      (default; user can override)
#
#   Mode C — Harbor for both pulls and pushes
#       PULL: localhost/cgr-proxy/$CHAINGUARD_ORG (anonymous, Harbor pull-through)
#       PUSH: localhost/library    (Harbor admin creds embedded)
#
# Persists the choice in .env (PULL_REGISTRY, PUSH_REGISTRY, HARBOR_ENABLED)
# and either bootstraps the OIDC assumed identity (Mode A) or stands up the
# Harbor kind cluster (Modes B/C). Re-run any time to switch modes.
set -euo pipefail

cd "$(dirname "$0")"

# Pick up CHAINGUARD_ORG (and any prior choices) from .env if present.
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JENKINS_OIDC_ISSUER="${JENKINS_OIDC_ISSUER:-https://localhost:8080/oidc}"

prompt_yn() {
  # $1=question, $2=default ("y" or "n")
  local q="$1" def="$2" hint ans
  if [[ "$def" == "y" ]]; then hint="(Y/n)"; else hint="(y/N)"; fi
  read -rp "$q $hint: " ans
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

# Prompt for the Chainguard org if .env didn't supply one. The answer gets
# persisted to .env in Phase 1 below, so subsequent re-runs go straight
# through without prompting.
if [[ -z "${CHAINGUARD_ORG:-}" ]]; then
  echo "==> No Chainguard org configured."
  echo "    Examples: 'chainguard' (public catalog) or 'your-org.example.com'."
  while [[ -z "${CHAINGUARD_ORG:-}" ]]; do
    read -rp "    Enter your Chainguard org: " CHAINGUARD_ORG
  done
  echo
fi
ORG="$CHAINGUARD_ORG"
echo "==> Chainguard org: ${ORG}"
echo

if prompt_yn "Install Harbor as a pull-through cache for cgr.dev/${ORG}/*?" n; then
  HARBOR_ENABLED=true
  if prompt_yn "Push pipeline-built images to Harbor (rather than ttl.sh)?" n; then
    PUSH_TO_HARBOR=true
  else
    PUSH_TO_HARBOR=false
  fi
else
  HARBOR_ENABLED=false
  PUSH_TO_HARBOR=false
fi

# Where to push if not Harbor. No baked-in default — if a previous setup.sh
# run persisted a value in .env, offer that as the suggested default;
# otherwise loop until the user enters something explicit.
if [[ "$PUSH_TO_HARBOR" == "true" ]]; then
  PUSH_REGISTRY="localhost/library"
else
  PUSH_REGISTRY_DEFAULT="${PUSH_REGISTRY:-}"
  PUSH_REGISTRY=""
  while [[ -z "$PUSH_REGISTRY" ]]; do
    if [[ -n "$PUSH_REGISTRY_DEFAULT" ]]; then
      read -rp "Where should pipelines push their built images? [last used: ${PUSH_REGISTRY_DEFAULT}]: " PUSH_REG_INPUT
      PUSH_REGISTRY="${PUSH_REG_INPUT:-$PUSH_REGISTRY_DEFAULT}"
    else
      read -rp "Where should pipelines push their built images? (e.g. ttl.sh/your-prefix): " PUSH_REGISTRY
    fi
  done
fi

# Where to pull cgr.dev images from.
if [[ "$HARBOR_ENABLED" == "true" ]]; then
  PULL_REGISTRY="localhost/cgr-proxy/${ORG}"
else
  PULL_REGISTRY="cgr.dev/${ORG}"
fi

echo
echo "==> Mode summary:"
echo "    Harbor enabled: ${HARBOR_ENABLED}"
echo "    Pulls from:     ${PULL_REGISTRY}"
echo "    Pushes to:      ${PUSH_REGISTRY}"
echo

# ---- Phase 0: preflight image accessibility check ------------------------
# Probe every image the demo will pull from cgr.dev/$ORG/ before spinning
# anything up. Catches misconfigured org names, missing access grants, and
# stale chainctl sessions early — with a clear list of what's missing —
# instead of letting docker build / kubectl apply fail several minutes in
# with cryptic auth errors. Set SKIP_PREFLIGHT=1 to bypass.

CORE_IMAGES=(
  # Controller build dependencies (Dockerfile.jenkins multi-stage sources).
  jenkins:2-lts-jdk21-dev
  docker-cli:29
  chainctl:latest-dev
  # One-shot tools spawned by pipelines or shared-library helpers.
  cosign:latest-dev
  crane:latest-dev
  # cgImage catalog tags. Tags only — manifest probes resolve the
  # current-tip digest, which is what cgImage's pinned digests track too.
  maven:3-jdk17-dev
  amazon-corretto-jre:17-dev
  maven:3-jdk8-dev
  adoptium-jre:adoptium-openjdk-8-dev
  jdk:openjdk-21-dev
  jre:openjdk-21-dev
  python:3.14-dev
  python:3.14
  python:3.12-dev
  python:3.12
  node:22-dev
  node:22
  node:25-dev
  node:25-slim
)

# Harbor microservice + ingress images, only needed in Modes B/C.
HARBOR_IMAGES=(
  harbor-portal:latest
  harbor-core:latest
  harbor-jobservice:latest
  harbor-registry:latest
  harbor-trivy-adapter:latest
  harbor-db:latest
  ingress-nginx-controller:latest
  kube-webhook-certgen:latest
)

if [[ "${SKIP_PREFLIGHT:-0}" != "1" ]]; then
  IMAGES_TO_CHECK=("${CORE_IMAGES[@]}")
  if [[ "$HARBOR_ENABLED" == "true" ]]; then
    IMAGES_TO_CHECK+=("${HARBOR_IMAGES[@]}")
  fi

  echo "==> Preflight: probing ${#IMAGES_TO_CHECK[@]} images at cgr.dev/${ORG}/..."
  # Parallel HEAD-style probes via `docker manifest inspect`. Each subshell
  # writes one line per image (`OK <tag>` or `FAIL <tag>`) — line-atomic on
  # Linux for short writes — to a tempfile that we then iterate in INPUT
  # order so the printed list matches the array above.
  PREFLIGHT_RESULTS=$(mktemp)
  trap 'rm -f "$PREFLIGHT_RESULTS"' EXIT
  # Export ORG so the `sh -c` invocations spawned by xargs see it via the
  # environment rather than via shell-quoted splicing of "$ORG" into the
  # script body — a CHAINGUARD_ORG value containing a quote or shell
  # metacharacter would otherwise corrupt the probe command.
  export ORG
  printf '%s\n' "${IMAGES_TO_CHECK[@]}" | xargs -P 8 -I {} sh -c '
    if docker manifest inspect "cgr.dev/${ORG}/{}" >/dev/null 2>&1; then
      echo "OK {}"
    else
      echo "FAIL {}"
    fi
  ' >> "$PREFLIGHT_RESULTS" || true

  # ANSI colors. Always emit — setup.sh is interactive.
  PF_GREEN=$'\033[32m'
  PF_RED=$'\033[31m'
  PF_RESET=$'\033[0m'
  PF_MISSING=0
  for img in "${IMAGES_TO_CHECK[@]}"; do
    if grep -qx "OK $img" "$PREFLIGHT_RESULTS"; then
      printf '    %s✓%s cgr.dev/%s/%s\n' "$PF_GREEN" "$PF_RESET" "$ORG" "$img"
    else
      printf '    %s✗%s cgr.dev/%s/%s\n' "$PF_RED"   "$PF_RESET" "$ORG" "$img"
      PF_MISSING=$((PF_MISSING + 1))
    fi
  done
  rm -f "$PREFLIGHT_RESULTS"
  trap - EXIT

  if (( PF_MISSING > 0 )); then
    echo >&2
    echo "ERROR: ${PF_MISSING} image(s) not accessible at cgr.dev/${ORG}/." >&2
    echo "Possible causes:" >&2
    echo "  - You're not authenticated to cgr.dev. Try:" >&2
    echo "      chainctl auth login" >&2
    echo "      chainctl auth configure-docker" >&2
    echo "  - Your org doesn't have access to these images yet — request" >&2
    echo "    them at https://console.chainguard.dev/ or via Chainguard support." >&2
    echo "  - CHAINGUARD_ORG is wrong (currently '${ORG}'). Edit .env or unset" >&2
    echo "    the variable to be re-prompted." >&2
    echo >&2
    echo "Bypass with SKIP_PREFLIGHT=1 ./setup.sh if you know what you're doing." >&2
    echo "Aborting setup." >&2
    exit 1
  fi
  echo "    All ${#IMAGES_TO_CHECK[@]} images accessible."
  echo
else
  echo "==> Preflight: SKIP_PREFLIGHT=1 set, skipping image accessibility check."
  echo
fi

# ---- Phase 1a: ensure cosign keypair exists -----------------------------
# Pipelines that build OCI images sign their pushed images with cosign and
# then verify the signature in the same build. The keypair lives at
# /tmp/cgjenkins-home/.secrets/ — same absolute path on host and in the
# Jenkins container — so cgSign() can spawn a sibling cosign container
# (`docker run --network host …`) that bind-mounts the same path back in.
# The keypair is generated once (cached) and reused on every re-run.

COSIGN_DIR=/tmp/cgjenkins-home/.secrets
echo "==> Ensuring cosign keypair is present in ${COSIGN_DIR}/..."
mkdir -p "$COSIGN_DIR"
if [[ ! -f "$COSIGN_DIR/cosign.key" ]]; then
  echo "    Generating new cosign keypair..."
  GEN_COSIGN_PASSWORD="$(openssl rand -base64 24)"
  printf '%s' "$GEN_COSIGN_PASSWORD" > "$COSIGN_DIR/cosign.password"
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e "COSIGN_PASSWORD=$GEN_COSIGN_PASSWORD" \
    -v "$COSIGN_DIR:/work" \
    -w /work \
    --entrypoint=/usr/bin/cosign \
    "cgr.dev/${ORG}/cosign:latest-dev" \
    generate-key-pair
  unset GEN_COSIGN_PASSWORD
  echo "    Keypair written to ${COSIGN_DIR}/cosign.{key,pub,password}"
else
  echo "    Reusing existing keypair in ${COSIGN_DIR}/cosign.{key,pub,password}"
fi
# Normalize ownership + perms via a one-shot root container so all three
# files end up owned by uid 1000 (the Jenkins controller's uid) with mode
# 600. JCasC reads them at boot via `${readFile:…}` / `${readFileBase64:…}`
# across the bind mount as uid 1000 — file is owner-readable so that path
# works. Setup.sh itself no longer needs to read these files (the cosign
# passphrase is read directly by JCasC, not round-tripped through the host
# env), so the host user losing read access is fine.
#
# Doing this in a container lets us chown to a uid we don't own without
# requiring sudo on the host. Teardown.sh already falls back to sudo when
# `rm -rf /tmp/cgjenkins-home` hits files owned by uid 1000 on Linux —
# macOS bind-mounts squash ownership for the host user so plain rm works.
echo "    Normalizing cosign secret ownership to uid 1000 + chmod 600..."
docker run --rm --user 0:0 \
  -v "$COSIGN_DIR:/work" \
  --entrypoint=sh \
  "cgr.dev/${ORG}/cosign:latest-dev" \
  -c 'chown 1000:1000 /work/cosign.key /work/cosign.pub /work/cosign.password && chmod 600 /work/cosign.key /work/cosign.pub /work/cosign.password'

# ---- Phase 1: write .env first so docker compose picks up the new mode ----

echo "==> Writing mode flags to .env..."
[[ -f .env ]] || cp .env.example .env
update_env() {
  local key="$1" value="$2"
  # Reject values containing a newline — they'd produce a .env line that
  # docker-compose / JCasC env-var parsers would silently misinterpret
  # (the value would terminate at the embedded newline and the remainder
  # would be parsed as a separate key). docker-compose's dotenv format
  # supports escaped/quoted multi-line values but JCasC's `${VAR}` resolver
  # doesn't, so the safest rule is no newlines at all.
  if [[ "$value" == *$'\n'* ]]; then
    echo "ERROR: update_env value for ${key} contains a newline — refusing to corrupt .env." >&2
    exit 1
  fi
  # Rewrite .env line-by-line in pure bash rather than passing $value through
  # sed. A user-supplied registry/org could contain &, \, |, or other sed
  # special chars (the s/// replacement side treats & as the matched string
  # and \N as a backref), which would silently corrupt the .env. Building
  # the file in a temp and atomically renaming avoids that whole class of bug.
  local tmp
  tmp=$(mktemp)
  local found=0
  if [[ -f .env ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == "${key}="* ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
        found=1
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    done < .env
  fi
  if (( found == 0 )); then
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  mv "$tmp" .env
}
update_env CHAINGUARD_ORG "$ORG"
update_env HARBOR_ENABLED "$HARBOR_ENABLED"
update_env PULL_REGISTRY  "$PULL_REGISTRY"
update_env PUSH_REGISTRY  "$PUSH_REGISTRY"
# Persist the Harbor admin password if Harbor is enabled. Default to the
# chart's own default ("Harbor12345") so an unmodified first-run works, but
# allow user override by pre-setting HARBOR_ADMIN_PASSWORD in .env. Same
# value drives the Helm chart, the Terraform harbor provider, and cgLogin's
# Mode C push-auth — keeping them all wired off one env var means there's
# only one knob to rotate.
if [[ "$HARBOR_ENABLED" == "true" ]]; then
  HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-Harbor12345}"
  update_env HARBOR_ADMIN_PASSWORD "$HARBOR_ADMIN_PASSWORD"
fi

# ---- Phase 2: (re)create Jenkins with the new env so its OIDC signing key
#               is the one we'll upload to Chainguard in Phase 3. ----

echo "==> Bringing up Jenkins (force-recreate to pick up new env)..."
docker compose up -d --build --force-recreate jenkins
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null "$JENKINS_URL/login" 2>/dev/null; then break; fi
  if (( i == 60 )); then
    echo "ERROR: Jenkins did not respond at $JENKINS_URL/login within 2 minutes." >&2
    exit 1
  fi
  sleep 2
done
echo "==> Jenkins is up at $JENKINS_URL"

# ---- Phase 3: mode-specific bootstrap ----

if [[ "$HARBOR_ENABLED" == "true" ]]; then
  echo "==> Harbor mode — generating a long-lived pull token for Harbor..."
  # Harbor needs durable creds against cgr.dev (it can't use Jenkins' per-
  # build OIDC tokens). Reuse a cached one if present, else generate.
  PULL_FILE=harbor/.pull-token
  if [[ -f "$PULL_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$PULL_FILE"
  fi
  if [[ -z "${PULL_USER:-}" || -z "${PULL_PASS:-}" ]]; then
    # Ask chainctl for machine-readable JSON rather than scraping the
    # human-readable suggestion text (`--username "X" --password "Y"`) with
    # grep+sed — that text is presentation, not contract, and would break
    # silently if chainctl ever reformatted it. Today the JSON shape is
    # { "id": "<uidp>", "password": "<jwt>" }; accept a couple of likely
    # alternative key names for forward-compat. python3 parses without
    # adding a jq dependency (we already use it for the JWKS validator).
    TOKEN_JSON=$(chainctl auth pull-token create --parent="$ORG" --name="harbor-cgr-proxy" --ttl=720h -o json)
    PULL_USER=$(printf '%s' "$TOKEN_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or d.get("username") or "")')
    PULL_PASS=$(printf '%s' "$TOKEN_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("password") or d.get("secret") or "")')
    if [[ -z "$PULL_USER" || -z "$PULL_PASS" ]]; then
      echo "ERROR: failed to extract id/password from chainctl pull-token JSON. Raw response:" >&2
      echo "$TOKEN_JSON" >&2
      exit 1
    fi
    mkdir -p harbor
    cat > "$PULL_FILE" <<EOF
PULL_USER='$PULL_USER'
PULL_PASS='$PULL_PASS'
EOF
    chmod 600 "$PULL_FILE"
    echo "    Saved pull token to $PULL_FILE (gitignored)."
  fi

  echo "==> Deploying Harbor (kind + Helm + Terraform)..."
  CHAINGUARD_ORG="$ORG" PULL_USER="$PULL_USER" PULL_PASS="$PULL_PASS" \
    HARBOR_ADMIN_PASSWORD="$HARBOR_ADMIN_PASSWORD" \
    harbor/deploy.sh

  # In Harbor mode the Jenkins OIDC assumed identity isn't used at runtime,
  # but we leave it in .env from any prior bootstrap (cleared below).
  IDENTITY_FILE=shared-libraries/cg-images/IDENTITY
  : > "$IDENTITY_FILE"  # truncate; cgLogin will be skipped via env flag
else
  echo "==> Direct-cgr.dev mode — bootstrapping the OIDC assumed identity..."
  JWKS_FILE="iac/jenkins-jwks.json"
  mkdir -p iac
  curl -fsS "$JENKINS_URL/oidc/jwks" > "$JWKS_FILE"
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$JWKS_FILE" >/dev/null 2>&1; then
    echo "ERROR: $JWKS_FILE is not valid JSON. Got:" >&2
    cat "$JWKS_FILE" >&2
    exit 1
  fi
  echo "    Fetched $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("keys",[])))' "$JWKS_FILE") signing key(s)."
  ( cd iac
    terraform init -input=false -upgrade
    terraform apply -input=false -auto-approve \
      -var="chainguard_group_name=${ORG}" \
      -var="jenkins_issuer_url=${JENKINS_OIDC_ISSUER}"
  )
  UIDP=$(cd iac && terraform output -raw identity_uidp)
  if [[ -z "$UIDP" ]]; then
    echo "ERROR: terraform output identity_uidp was empty." >&2
    exit 1
  fi
  echo "    Created identity: ${UIDP}"
  printf '%s\n' "$UIDP" > shared-libraries/cg-images/IDENTITY
fi

echo
echo "==> Done."
echo "    Open $JENKINS_URL (admin/admin) and trigger any pipeline."
echo
case "$HARBOR_ENABLED-$PUSH_TO_HARBOR" in
  false-false)
    echo "    Mode: direct cgr.dev with OIDC assumed identity for pulls."
    echo "    Pushes go to $PUSH_REGISTRY."
    ;;
  true-false)
    echo "    Mode: Harbor proxy cache for pulls (anonymous)."
    echo "    Pushes go to $PUSH_REGISTRY."
    echo "    Harbor UI: https://localhost/harbor (admin / ${HARBOR_ADMIN_PASSWORD}; click through cert warning)"
    ;;
  true-true)
    echo "    Mode: Harbor for both pulls and pushes."
    echo "    Pushes land in Harbor's library project."
    echo "    Harbor UI: https://localhost/harbor (admin / ${HARBOR_ADMIN_PASSWORD}; click through cert warning)"
    ;;
esac
