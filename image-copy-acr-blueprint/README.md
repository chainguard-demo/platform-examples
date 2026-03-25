# `image-copy-acr-blueprint`

This is a Bicep-first starter blueprint for re-creating `image-copy-acr` as a public-repo Azure deployment artifact.

It keeps the current direction of the example:

- Azure Container Apps is the default runtime path.
- The Container App uses a system-assigned managed identity for ACR pull and push.
- Chainguard source-registry auth is represented in the parameter surface and currently still requires a bootstrap secret input.

This is intentionally a practical starting point, not a production-ready system.

## Deploy Buttons

# https://github.com/justinprince/platform-examples

# Prod
[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fchainguard-dev%2Fplatform-examples%2Fmain%2Fimage-copy-acr-blueprint%2Finfra%2Fazuredeploy.json)

[![Deploy to Azure](https://aka.ms/deploytoazuregovbutton)](https://portal.azure.us/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fchainguard-dev%2Fplatform-examples%2Fmain%2Fimage-copy-acr-blueprint%2Finfra%2Fazuredeploy.json)

# Test
[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjustinprince%2Fplatform-examples%2Fmain%2Fimage-copy-acr-blueprint%2Finfra%2Fazuredeploy.json)

[![Deploy to Azure](https://aka.ms/deploytoazuregovbutton)](https://portal.azure.us/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjustinprince%2Fplatform-examples%2Fmain%2Fimage-copy-acr-blueprint%2Finfra%2Fazuredeploy.json)

## What This Blueprint Deploys

- A resource group for the mirror service.
- An Azure Container Apps environment.
- A public Azure Container App for the image-copy webhook receiver.
- `AcrPull` and `AcrPush` role assignments on an existing target ACR.

The app surface matches the current `image-copy-acr` service shape:

- `ISSUER_URL`
- `API_ENDPOINT`
- `GROUP_NAME`
- `GROUP`
- `IDENTITY`
- `DST_REPO`
- `ACR_REGISTRY`
- `IGNORE_REFERRERS`
- `VERIFY_SIGNATURES`
- `PORT`
- bootstrap `OIDC_TOKEN`

## Folder Layout

- [infra/main.bicep](/Users/justinprince/repos/forks/platform-examples/image-copy-acr-blueprint/infra/main.bicep): subscription-scope entrypoint that creates the resource group and invokes the workload module.
- [infra/azuredeploy.json](/Users/justinprince/repos/forks/platform-examples/image-copy-acr-blueprint/infra/azuredeploy.json): ARM JSON entrypoint for the public deploy buttons.
- [infra/modules/workload.bicep](/Users/justinprince/repos/forks/platform-examples/image-copy-acr-blueprint/infra/modules/workload.bicep): resource-group-scope Container Apps deployment and ACR RBAC.
- [infra/main.parameters.json](/Users/justinprince/repos/forks/platform-examples/image-copy-acr-blueprint/infra/main.parameters.json): starter parameter file for commercial Azure.
- [infra/main.gov.parameters.json](/Users/justinprince/repos/forks/platform-examples/image-copy-acr-blueprint/infra/main.gov.parameters.json): starter parameter file for Azure US Government.

## Minimal Usage

Commercial Azure:

```sh
az deployment sub create \
  --location eastus \
  --template-file infra/main.bicep \
  --parameters @infra/main.parameters.json
```

Azure US Government:

```sh
az cloud set --name AzureUSGovernment
az deployment sub create \
  --location usgovvirginia \
  --template-file infra/main.bicep \
  --parameters @infra/main.gov.parameters.json
```

## Important Inputs

- `containerImage`: removed. The image must be built into the target ACR before deployment using `az acr build` (the deployment uses the fixed image name `cgr-image-copy:v1` in the target registry). This makes the deployment deterministic and avoids runtime bootstrap pull races.
- `acrName`, `acrResourceGroupName`: the existing target registry.
- `dstRepoPrefix`: destination prefix in ACR; may include the registry host or just the repository path.
- `chainguardOrgName`, `identityId`: Chainguard organization name and identity ID used by the service.
- `chainguardOidcToken`: bootstrap secret input for the current app code path (optional). The blueprint also creates an Azure Key Vault with a discoverable static name where operators can store this secret instead.
- `containerCpu`: defaults to `0.25` so the starter shape matches a minimal Container Apps deployment.

**Key Vault and secrets**

- This blueprint creates an Azure Key Vault named `<workloadName>-kv` (for example `image-copy-acr-kv`) in the same resource group. It also creates a placeholder secret named `chainguard-oidc-token` with value `REPLACE_ME` to make the secret name and location discoverable.
- After deployment, replace the placeholder with the real secret. Example:

```bash
# Replace values with your resource group and desired secret
az keyvault secret set \
  --vault-name <workloadName>-kv \
  --name chainguard-oidc-token \
  --value "<YOUR_BOOTSTRAP_OIDC_TOKEN>"
```

- Once the Key Vault contains the secret, consider migrating the app to read secrets from Key Vault or grant the app's managed identity permissions to the vault so it can fetch secrets at runtime rather than relying on bootstrap parameters.

## Current Gaps

- The deploy buttons still need real public GitHub raw URLs.
- `azuredeploy.json` is the button target, while `main.bicep` remains the editable source.
- First deploy still has an ACR bootstrap risk with system-assigned identity, because the app may need registry pull before `AcrPull` exists.
- The template can optionally build the runtime image for you during deployment using an Azure Deployment Script that runs `az acr build`. By default the template builds `cgr-image-copy:v1` into the target registry before creating or updating the Container App. You can still pre-build the image if you prefer.

  - The template accepts `dockerfilePath` (defaults to `Dockerfile`) and `utcValue` (default `utcNow()`). The `utcValue` is used as the deployment script `forceUpdateTag` so you can re-run the build by changing the value.

  - The deployment script runs `az acr build --registry <ACR_NAME> --image cgr-image-copy:v1 --file <dockerfilePath> .` in the target resource group.

  - The deployment script is created with a system-assigned identity and the template grants it `AcrPush` on the target ACR so the script can push the built image.
- `chainguardOidcToken` is a bootstrap mechanism. A better next step is workload identity or a secret-store-backed token acquisition flow for Chainguard auth.
- No Event Grid, subscription automation, custom domain, WAF, or production hardening is included.
- No portal UI definition is included yet; the parameter files are the current operator interface.
