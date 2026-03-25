# `image-copy-acr`

This deploys a small service that listens for `registry.push` events from a private Chainguard Registry group and mirrors pushed images into Azure Container Registry.

The intended path is Azure Container Apps. The Terraform in `iac/` deploys the service and exposes a public HTTPS endpoint for the webhook.

## Setup

Build and push the service image to your ACR:

```sh
REGISTRY_NAME=""
az acr login --name ${REGISTRY_NAME}
docker build -t ${REGISTRY_NAME}$.azurecr.io/image-copy-acr:latest .
docker push ${REGISTRY_NAME}.azurecr.io/image-copy-acr:latest
```

Create your Terraform vars file:

```sh
cd iac
cp terraform.tfvars.example terraform.tfvars
```

Fill in these values in `terraform.tfvars`:

- `registry_name`, `registry_resource_group_name`, `registry_server`: the target ACR resource and login server.
- `image`: the pushed service image, for example `myregistry.azurecr.io/image-copy-acr:latest`.
- `group_name`: the Chainguard group name to mirror from.
- `group`: the Chainguard group ID used to validate webhook requests.
- `identity`: the Chainguard identity ID used to pull image metadata and image contents.
- `dst_repo`: the ACR destination prefix, for example `myregistry.azurecr.io/mirrors`.
- `oidc_token`: the OIDC token exchanged for the Chainguard identity above.

Apply the Terraform:

```sh
cd iac
terraform init
terraform apply -var-file=terraform.tfvars
```

Terraform outputs the public URL for the service. Use that URL as the sink for your Chainguard `registry.push` subscription.

Images pushed to `cgr.dev/<group_name>/<repo>:<tag>` will be mirrored to `<dst_repo>/<repo>:<tag>`.

## Notes

- `ignore_referrers = true` keeps signatures and attestations out of the mirror.
- `verify_signatures = true` verifies signatures before copying.
- The Container App uses a system-assigned managed identity for ACR auth.
- Terraform grants that identity `AcrPull` and `AcrPush` on the target registry.
- `ACR_REGISTRY` is optional and defaults from `dst_repo`.

An Azure Functions example is still available under `iac/function`, but `iac/` is the default deployment path.
