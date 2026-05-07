#!/usr/bin/env bash
# Deploy a Harbor instance into a local kind cluster, configured to proxy
# cgr.dev/${CHAINGUARD_ORG}/* via a public Harbor project named "cgr-proxy".
# Adapted from chainguard-demo/cs-workshop/.../harbor/deploy-harbor.sh — same
# Helm + ingress-nginx + Terraform machinery, but driven by env vars instead
# of interactive prompts so setup.sh can call it non-interactively.
#
# Required env vars:
#   CHAINGUARD_ORG  Chainguard org to proxy (e.g. 'chainguard' or 'your-org.example.com')
#   PULL_USER       Pull-token username (Harbor uses this to talk to cgr.dev)
#   PULL_PASS       Pull-token password
#
# Optional:
#   KIND_CLUSTER_NAME  default: jenkins-harbor
#
# Idempotent: re-running re-applies the manifests + Helm values + Terraform.
set -euo pipefail

cd "$(dirname "$0")"

: "${CHAINGUARD_ORG:?CHAINGUARD_ORG must be set}"
: "${PULL_USER:?PULL_USER must be set (Chainguard pull-token username)}"
: "${PULL_PASS:?PULL_PASS must be set (Chainguard pull-token password)}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-jenkins-harbor}"

export ORG_NAME="${CHAINGUARD_ORG}"
export REGISTRY_URL="cgr.dev/${CHAINGUARD_ORG}"

for tool in kind kubectl helm terraform envsubst; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not found in PATH" >&2
    exit 1
  fi
done

if ! kind get clusters | grep -qx "$KIND_CLUSTER_NAME"; then
  echo "==> Creating kind cluster '$KIND_CLUSTER_NAME'..."
  kind create cluster --name "$KIND_CLUSTER_NAME" --config kind/config.yaml
  kubectl wait --for=condition=Ready "node/${KIND_CLUSTER_NAME}-control-plane" --timeout=2m
else
  echo "==> kind cluster '$KIND_CLUSTER_NAME' already exists, reusing it."
  kubectl config use-context "kind-${KIND_CLUSTER_NAME}"
fi

echo "==> Rendering manifests with REGISTRY_URL=${REGISTRY_URL}..."
envsubst < cg/manifests/deploy-ingress-nginx.template > cg/manifests/deploy-ingress-nginx.yaml
envsubst < cg/helm/values.template               > cg/helm/values.yaml

# Namespaces (idempotent).
kubectl get ns ingress-nginx >/dev/null 2>&1 || kubectl create ns ingress-nginx
kubectl get ns harbor        >/dev/null 2>&1 || kubectl create ns harbor

echo "==> Creating regcred docker-registry secrets so the cluster can pull from cgr.dev..."
for ns in ingress-nginx harbor; do
  kubectl -n "$ns" create secret docker-registry regcred \
    --docker-server="cgr.dev" \
    --docker-username="$PULL_USER" \
    --docker-password="$PULL_PASS" \
    --dry-run=client -o yaml | kubectl apply -f -
done

echo "==> Deploying ingress-nginx..."
kubectl apply -f cg/manifests/deploy-ingress-nginx.yaml
kubectl wait --for=condition=Ready -n ingress-nginx pod \
  --selector=app.kubernetes.io/name=ingress-nginx \
  --selector=app.kubernetes.io/component=controller \
  --timeout=3m

echo "==> Installing/upgrading Harbor via Helm..."
helm repo add harbor https://helm.goharbor.io >/dev/null 2>&1 || true
helm repo update harbor >/dev/null
helm upgrade --install harbor harbor/harbor -n harbor -f cg/helm/values.yaml --wait --timeout=10m

echo "==> Waiting for Harbor's web ingress to respond..."
# -k: the chart-issued cert is self-signed; we just need to know the
# endpoint is alive, not validate trust. See values.template for why we
# can't run plain HTTP (Harbor #22010).
for i in $(seq 1 60); do
  if curl -fsSk -o /dev/null https://localhost/api/v2.0/health 2>/dev/null; then
    break
  fi
  if (( i == 60 )); then
    echo "ERROR: Harbor /api/v2.0/health did not respond at https://localhost/ within 2 minutes." >&2
    exit 1
  fi
  sleep 2
done

echo "==> Configuring Harbor with Terraform (cgr.dev proxy registry + cgr-proxy project)..."
export PULL_USER PULL_PASS
envsubst < terraform/terraform.templatevars > terraform/terraform.tfvars
( cd terraform
  terraform init -input=false -upgrade
  terraform apply -input=false -auto-approve
)

echo "==> Done."
echo "    Harbor UI:       https://localhost/harbor (admin / Harbor12345; click through cert warning)"
echo "    Proxy cache URL: localhost/cgr-proxy/${CHAINGUARD_ORG}/<image>:<tag>"
echo "    Push project:    localhost/library/<image>:<tag>"
