#!/usr/bin/env bash
# Tear down the Harbor kind cluster created by deploy.sh.
set -euo pipefail
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-jenkins-harbor}"
if kind get clusters | grep -qx "$KIND_CLUSTER_NAME"; then
  echo "==> Deleting kind cluster '$KIND_CLUSTER_NAME'..."
  kind delete cluster --name "$KIND_CLUSTER_NAME"
else
  echo "kind cluster '$KIND_CLUSTER_NAME' not present — nothing to do."
fi
