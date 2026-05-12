#!/usr/bin/env bash
# Tear down everything setup.sh + the demo created:
#   - Harbor kind cluster (if present)
#   - Chainguard assumed identity (terraform destroy on iac/, if state present)
#   - Jenkins controller container + image
#   - JENKINS_HOME bind-mount at /tmp/cgjenkins-home (needs sudo)
#   - cosign keys (under /tmp/cgjenkins-home/.secrets/, wiped with cgjenkins-home)
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

echo "==> Tearing down Harbor (kind cluster, if any)..."
if [[ -x harbor/teardown.sh ]]; then
  harbor/teardown.sh
fi

echo "==> Releasing Chainguard assumed identity (if Terraform state present)..."
TF_DESTROY_FAILED=0
if [[ -f iac/terraform.tfstate ]]; then
  if [[ -z "${CHAINGUARD_ORG:-}" ]]; then
    echo "    SKIPPING: CHAINGUARD_ORG not set in .env, can't run terraform destroy."
    echo "    The identity will linger; clean it up manually with chainctl iam identities delete."
    TF_DESTROY_FAILED=1
  else
    # Don't abort the whole teardown if destroy fails — the remaining steps
    # (stopping Jenkins, wiping /tmp/cgjenkins-home, removing local state)
    # are still worth doing. But we DO surface the failure so the user knows
    # to clean up the assumed identity manually, and we exit non-zero at the
    # end so CI / scripted callers see it.
    if ! ( cd iac && terraform destroy -auto-approve \
        -var="chainguard_group_name=${CHAINGUARD_ORG}" \
        -var="jenkins_issuer_url=${JENKINS_OIDC_ISSUER:-https://localhost:8080/oidc}" ); then
      TF_DESTROY_FAILED=1
      echo "    WARNING: terraform destroy failed. The Chainguard assumed identity may still exist." >&2
      echo "    Inspect with: chainctl iam identities list --parent='${CHAINGUARD_ORG}'" >&2
      echo "    Delete manually with: chainctl iam identities delete <id>" >&2
    fi
  fi
fi

echo "==> Stopping Jenkins (docker compose down)..."
# Print full output; truncating with `tail -5` hides earlier errors that
# would explain why compose-down failed.
docker compose down --rmi local --remove-orphans

echo "==> Removing /tmp/cgjenkins-home..."
# On macOS + OrbStack the bind-mount is owned by the host user (no sudo).
# On Linux it may be owned by uid 1000 from inside the container, which maps
# to a different host user — fall back to sudo only when plain rm fails.
if ! rm -rf /tmp/cgjenkins-home 2>/dev/null; then
  echo "    Plain rm failed, retrying with sudo..."
  sudo rm -rf /tmp/cgjenkins-home
fi

echo "==> Cleaning generated files..."
rm -rf .secrets
rm -f  harbor/.pull-token
rm -f  shared-libraries/cg-images/IDENTITY
# Only wipe the iac/ Terraform state when destroy actually succeeded.
# Preserving it on failure (or when destroy was skipped because
# CHAINGUARD_ORG wasn't set) lets the user re-run ./teardown.sh after
# fixing the cause and still have Terraform clean up the assumed identity
# — without the state file there's no handle on the remote resource and
# the identity gets orphaned. Harbor terraform state is independent (the
# kind cluster gets blown away wholesale by harbor/teardown.sh), so we
# clean it unconditionally.
if (( TF_DESTROY_FAILED == 0 )); then
  rm -rf iac/.terraform iac/terraform.tfstate iac/terraform.tfstate.backup iac/jenkins-jwks.json
else
  echo "    Preserving iac/terraform.tfstate so a future ./teardown.sh can retry the destroy."
fi
rm -rf harbor/terraform/.terraform harbor/terraform/terraform.tfstate harbor/terraform/terraform.tfstate.backup harbor/terraform/terraform.tfvars
rm -f  harbor/cg/helm/values.yaml harbor/cg/manifests/deploy-ingress-nginx.yaml

if [[ "$WIPE_ENV" == "true" ]]; then
  rm -f .env
  echo "    Removed .env."
fi

echo
if (( TF_DESTROY_FAILED == 1 )); then
  echo "==> Done — WITH WARNINGS (terraform destroy was skipped or failed; see above)." >&2
  echo "    Re-run ./setup.sh to bootstrap from scratch."
  exit 1
fi
echo "==> Done. Re-run ./setup.sh to bootstrap from scratch."
