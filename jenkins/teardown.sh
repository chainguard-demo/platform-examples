#!/usr/bin/env bash
# Tear down everything setup.sh + the demo created:
#   - Harbor kind cluster (if present)
#   - Chainguard assumed identity (terraform destroy on iac/, if state present)
#   - Jenkins controller container + image
#   - JENKINS_HOME bind-mount at /tmp/cgjenkins-home (needs sudo)
#   - .secrets/, harbor/.pull-token, IDENTITY file, terraform state files
#
# Leaves .env in place (so re-running setup.sh remembers your CHAINGUARD_ORG
# choice). Pass --wipe-env to remove that too.
set -euo pipefail

cd "$(dirname "$0")"

WIPE_ENV=false
for arg in "$@"; do
  case "$arg" in
    --wipe-env) WIPE_ENV=true ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

cat <<EOF
This will:
  1. Tear down the Harbor kind cluster (if running).
  2. Run \`terraform destroy\` in iac/ (releases the Chainguard assumed identity, if any).
  3. Stop and remove the Jenkins controller container.
  4. Remove /tmp/cgjenkins-home (needs sudo).
  5. Remove .secrets/, harbor/.pull-token, shared-libraries/cg-images/IDENTITY,
     and the local Terraform state files in iac/ and harbor/terraform/.
$( [[ "$WIPE_ENV" == "true" ]] && echo "  6. Remove .env." )
EOF
echo
read -rp "Continue? [y/N]: " ans
[[ "$ans" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

# Source .env if present (for ORG / settings that affect cleanup).
[[ -f .env ]] && { set -a; source .env; set +a; } || true

echo "==> 1/5 Tearing down Harbor (kind cluster, if any)..."
if [[ -x harbor/teardown.sh ]]; then
  harbor/teardown.sh
fi

echo "==> 2/5 Releasing Chainguard assumed identity (if Terraform state present)..."
if [[ -f iac/terraform.tfstate ]]; then
  ( cd iac && terraform destroy -auto-approve \
      -var="chainguard_group_name=${CHAINGUARD_ORG:-smalls.xyz}" \
      -var="jenkins_issuer_url=${JENKINS_OIDC_ISSUER:-https://localhost:8080/oidc}" || true )
fi

echo "==> 3/5 Stopping Jenkins (docker compose down)..."
docker compose down --rmi local --remove-orphans 2>&1 | tail -5

echo "==> 4/5 Removing /tmp/cgjenkins-home..."
# On macOS + OrbStack the bind-mount is owned by the host user (no sudo).
# On Linux it may be owned by uid 1000 from inside the container, which maps
# to a different host user — fall back to sudo only when plain rm fails.
if ! rm -rf /tmp/cgjenkins-home 2>/dev/null; then
  echo "    Plain rm failed, retrying with sudo..."
  sudo rm -rf /tmp/cgjenkins-home
fi

echo "==> 5/5 Cleaning generated files..."
rm -rf .secrets
rm -f  harbor/.pull-token
rm -f  shared-libraries/cg-images/IDENTITY
rm -rf iac/.terraform iac/terraform.tfstate iac/terraform.tfstate.backup iac/jenkins-jwks.json
rm -rf harbor/terraform/.terraform harbor/terraform/terraform.tfstate harbor/terraform/terraform.tfstate.backup harbor/terraform/terraform.tfvars
rm -f  harbor/cg/helm/values.yaml harbor/cg/manifests/deploy-ingress-nginx.yaml

if [[ "$WIPE_ENV" == "true" ]]; then
  rm -f .env
  echo "    Removed .env."
fi

echo
echo "==> Done. Re-run ./setup.sh to bootstrap from scratch."
