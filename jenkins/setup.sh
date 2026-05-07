#!/usr/bin/env bash
# One-time setup for the Chainguard assumed-identity flow.
#
# Replaces the old long-lived pull-token approach. Now does:
#   1. Polls Jenkins until it's healthy and serving its OIDC discovery doc.
#   2. Fetches Jenkins' JWKS into iac/jenkins-jwks.json.
#   3. Runs `terraform apply` to create the Chainguard assumed identity
#      (with the JWKS uploaded statically) and a registry.pull rolebinding.
#   4. Reads the identity UIDP from terraform output and writes it into .env
#      as CHAINGUARD_IDENTITY=...
#   5. Restarts Jenkins so the new env var is visible to pipelines.
#
# Re-run this script if you change the Chainguard org, recreate the
# controller (which rotates Jenkins' OIDC signing key), or deliberately
# rotate the identity.
set -euo pipefail

cd "$(dirname "$0")"

# Pick up CHAINGUARD_ORG from .env if present so the script and docker-compose
# stay in sync without the user having to export the variable twice.
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

ORG="${CHAINGUARD_ORG:-smalls.xyz}"
JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
# Literal `iss` claim string Jenkins puts in OIDC tokens. Must match the
# scheme/host/port of jenkins.location.url in jenkins.yaml — currently
# https://localhost:8080/ (HTTPS to satisfy the chainguard_identity static
# block validator; static-mode is offline-verification only, the URL never
# has to resolve).
JENKINS_OIDC_ISSUER="${JENKINS_OIDC_ISSUER:-https://localhost:8080/oidc}"
JWKS_FILE="iac/jenkins-jwks.json"

echo "==> Verifying Jenkins is up at ${JENKINS_URL}..."
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null "${JENKINS_URL}/login"; then
    break
  fi
  if (( i == 60 )); then
    echo "ERROR: Jenkins did not respond at ${JENKINS_URL}/login within 2 minutes." >&2
    echo "Did you run 'docker compose up -d --build' first?" >&2
    exit 1
  fi
  sleep 2
done

echo "==> Fetching Jenkins JWKS to ${JWKS_FILE}..."
mkdir -p iac
curl -fsS "${JENKINS_URL}/oidc/jwks" > "${JWKS_FILE}"
if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${JWKS_FILE}" >/dev/null 2>&1; then
  echo "ERROR: ${JWKS_FILE} is not valid JSON. Got:" >&2
  cat "${JWKS_FILE}" >&2
  exit 1
fi
echo "    Fetched $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("keys",[])))' "${JWKS_FILE}") signing key(s)."

echo "==> Running terraform apply (chainguard_group=${ORG})..."
( cd iac
  terraform init -input=false -upgrade
  terraform apply -input=false -auto-approve \
    -var="chainguard_group_name=${ORG}" \
    -var="jenkins_issuer_url=${JENKINS_OIDC_ISSUER}"
)

UIDP=$( cd iac && terraform output -raw identity_uidp )
if [[ -z "$UIDP" ]]; then
  echo "ERROR: terraform output identity_uidp was empty." >&2
  exit 1
fi
echo "    Created identity: ${UIDP}"

echo "==> Writing identity UIDP to shared-libraries/cg-images/IDENTITY..."
# Pipelines read this file via cgLogin (filesystem-SCM live-loaded shared
# library) — no Jenkins restart required. We deliberately AVOID a restart
# here because restarting Jenkins regenerates the oidc-provider plugin's
# signing key, which would immediately invalidate the JWKS we just uploaded
# to Chainguard.
printf '%s\n' "${UIDP}" > shared-libraries/cg-images/IDENTITY

echo "==> Done. Bootstrap complete."
echo "    Open ${JENKINS_URL} (admin/admin) and trigger any pipeline — its"
echo "    Auth stage will exchange a fresh per-build OIDC token for a"
echo "    short-lived chainctl session and continue from there."
