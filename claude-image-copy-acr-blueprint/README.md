# Chainguard Image Copy — Azure Deployment

This ARM template deploys the full Azure infrastructure to build and run `cgr-image-copy:v1` using a Dockerfile in your repository, with Chainguard OIDC authentication via Azure Key Vault.

The ACR Task build is **triggered automatically** during deployment via a `Microsoft.Resources/deploymentScripts` resource — no manual build step required.

---

## Resources Deployed

| Resource | Description |
|---|---|
| **Azure Container Registry (ACR)** | Stores the built container image |
| **ACR Task** | Defines the Docker build: clones your repo, builds, pushes `cgr-image-copy:v1` |
| **Deployment Script** | Runs `az acr task run` automatically and polls until the build succeeds |
| **Script Runner Identity** | Dedicated managed identity with ACR Contributor, used only by the deployment script |
| **Azure Key Vault** | Holds the `chainguard-oidc-token` secret (placeholder — you update it post-deploy) |
| **App Managed Identity** | Grants the Container App permission to pull from ACR and read the Key Vault secret |
| **Container App Environment** | Managed environment for the Container App |
| **Azure Container App** | Runs the container; starts only after the deployment script confirms the build succeeded |
| **Log Analytics Workspace** | Captures Container App logs |

---

## Deployment Order (enforced by dependsOn)

```
Log Analytics → ACR + Key Vault + Managed Identities
     ↓
Role Assignments (ACR Pull, KV Secrets User, ACR Contributor for script)
     ↓
ACR Task (definition)
     ↓
Deployment Script (triggers az acr task run, polls to completion)
     ↓
Container App (guaranteed the image exists before starting)
```

---

## Prerequisites

- Azure CLI installed and logged in (`az login`)
- A resource group: `az group create --name <rg-name> --location eastus`
- Your `Dockerfile` committed to the Git repository referenced in the parameters
- The deploying principal must have permission to create role assignments (Owner or User Access Administrator on the resource group)

---

## Deployment Steps

### 1. Edit Parameters

Edit `azuredeploy.parameters.json`:

```json
{
  "containerRegistryName": { "value": "your-unique-acr-name" },
  "gitRepoUrl":            { "value": "https://github.com/YOUR_ORG/YOUR_REPO" },
  "gitRepoBranch":         { "value": "main" },
  "dockerfilePath":        { "value": "Dockerfile" },
  "gitRepoContextPath":    { "value": "." }
}
```

### 2. Deploy

```bash
az deployment group create \
  --resource-group <your-resource-group> \
  --template-file azuredeploy.json \
  --parameters @azuredeploy.parameters.json
```

The deployment will take 10–20 minutes depending on your Docker build time. The deployment script streams status every 20 seconds and fails the deployment loudly if the build fails.

### 3. Set the Chainguard OIDC Token ← Only manual step remaining

After deployment completes, update the Key Vault secret placeholder with your real token (the exact command is in the deployment outputs as `updateSecretCommand`):

```bash
az keyvault secret set \
  --vault-name <key-vault-name> \
  --name chainguard-oidc-token \
  --value "YOUR_ACTUAL_CHAINGUARD_OIDC_TOKEN"
```

Then restart the Container App to pick up the new secret value:

```bash
az containerapp revision restart \
  --resource-group <your-resource-group> \
  --name cgr-image-copy-app \
  --revision $(az containerapp revision list \
    --resource-group <your-resource-group> \
    --name cgr-image-copy-app \
    --query '[0].name' -o tsv)
```

---

## How the Build Trigger Works

The `Microsoft.Resources/deploymentScripts` resource (`trigger-acr-task-build`) runs an Azure CLI container that:

1. Calls `az acr task run --no-wait` to queue the build and capture the `runId`
2. Polls `az acr task show-run` every 20 seconds for up to 25 minutes
3. Exits `0` on `Succeeded` (deployment continues to Container App)
4. Exits `1` on `Failed`, `Canceled`, or timeout (deployment fails with logs)

The Container App has an explicit `dependsOn` the deployment script, so it is guaranteed to start only after the image is confirmed present in ACR.

---

## Private Repos

ACR Tasks can clone public repos natively. For **private repos**, add a PAT credential after deployment:

```bash
az acr task credential add \
  --registry <acr-name> \
  --name build-cgr-image-copy \
  --login-server github.com \
  --username YOUR_GITHUB_USERNAME \
  --password YOUR_PAT
```

Then re-run the task (or redeploy) to pick it up.

---

## Deployment Outputs

| Output | Description |
|---|---|
| `containerRegistryLoginServer` | ACR login server (e.g. `myacr.azurecr.io`) |
| `keyVaultName` | Name of the Key Vault |
| `keyVaultUri` | URI of the Key Vault |
| `containerAppFqdn` | FQDN of the running Container App |
| `acrTaskRunId` | The ACR run ID from the automated build |
| `updateSecretCommand` | Ready-to-run command to set the Chainguard token |

---

## File Layout Expected in Repo

```
your-repo/
├── Dockerfile                    ← Used by the ACR Task
├── azuredeploy.json              ← This template
└── azuredeploy.parameters.json
```
