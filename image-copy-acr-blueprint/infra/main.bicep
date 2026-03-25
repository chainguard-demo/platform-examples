targetScope = 'subscription'

@description('Resource group name for the image copy deployment.')
param resourceGroupName string

@description('Azure region for the deployment.')
param location string = 'eastus'

@description('Base name used to derive Azure resource names.')
param workloadName string = 'image-copy-acr'

// The image is built into the target ACR using `az acr build` and is not a
// direct deployment parameter. See README for build instructions.

@description('CPU requested by the Container App, for example 0.25, 0.5, or 1.0.')
param containerCpu string = '0.25'

@description('Memory requested by the Container App.')
param containerMemory string = '0.5Gi'

@description('Port exposed by the service.')
param containerPort int = 8080

@description('Name of the existing target Azure Container Registry.')
param acrName string

@description('Resource group that contains the target Azure Container Registry.')
param acrResourceGroupName string

@description('Destination repository prefix in ACR, including registry host, for example myregistry.azurecr.io/mirrors. If empty, defaults to "<acrName>.azurecr.io/cgr-image-copy"')
param dstRepoPrefix string = ''

// If the caller omitted `dstRepoPrefix`, synthesize a default using the
// provided `acrName`. This keeps the operator experience simple while still
// allowing explicit overrides.
var computedDstRepoPrefix = empty(dstRepoPrefix) ? '${acrName}.azurecr.io/cgr-image-copy' : dstRepoPrefix

@description('Path to the Dockerfile to use when building the runtime image. Can be a repo-local path.')
param dockerfilePath string = 'Dockerfile'

@description('UTC tag to force update of deployment script; default uses current time.')
param utcValue string = utcNow()

@description('Chainguard issuer URL.')
param issuerUrl string = 'https://issuer.enforce.dev'

@description('Chainguard API endpoint.')
param apiEndpoint string = 'https://console-api.enforce.dev'

@description('Chainguard source group name.')
param groupName string

@description('Chainguard source group ID.')
param groupId string

@description('Chainguard identity ID used by the service.')
param identityId string

@secure()
@description('Bootstrap OIDC token required by the current app code path for Chainguard token exchange.')
param chainguardOidcToken string = ''

@description('Skip referrer tags such as signatures and attestations.')
param ignoreReferrers bool = true

@description('Verify signatures before copying an image.')
param verifySignatures bool = false

@description('Apply external ingress to the Container App.')
param externalIngress bool = true

@description('Tags applied to created Azure resources.')
param tags object = {}

resource deploymentRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module workload './modules/workload.bicep' = {
  name: '${workloadName}-workload'
  scope: resourceGroup(resourceGroupName)
  params: {
    location: location
    workloadName: workloadName
    containerCpu: containerCpu
    containerMemory: containerMemory
    containerPort: containerPort
    acrName: acrName
    acrResourceGroupName: acrResourceGroupName
    dstRepoPrefix: computedDstRepoPrefix
    dockerfilePath: dockerfilePath
    utcValue: utcValue
    issuerUrl: issuerUrl
    apiEndpoint: apiEndpoint
    groupName: groupName
    groupId: groupId
    identityId: identityId
    chainguardOidcToken: chainguardOidcToken
    ignoreReferrers: ignoreReferrers
    verifySignatures: verifySignatures
    externalIngress: externalIngress
    tags: tags
  }
}

// Existing reference to the target ACR (in a possibly different resource group).
resource targetRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  scope: resourceGroup(subscription().subscriptionId, acrResourceGroupName)
  name: acrName
}
// Create role assignments in the ACR resource group via a module so cross-
// scope deployment rules are satisfied. The module will create AcrPull and
// AcrPush for the Container App identity and AcrPush for the deployment
// script identity.
module acrRoles './modules/acrRoles.bicep' = {
  name: '${workloadName}-acrRoles'
  scope: resourceGroup(subscription().subscriptionId, acrResourceGroupName)
  params: {
    acrName: acrName
    containerAppName: '${workloadName}-app'
    containerAppPrincipalId: workload.outputs.managedIdentityPrincipalId
    scriptPrincipalId: workload.outputs.buildScriptPrincipalId
  }
  dependsOn: [ workload ]
}

output resourceGroup string = deploymentRg.name
output containerAppName string = workload.outputs.containerAppName
output serviceUrl string = workload.outputs.serviceUrl
output managedIdentityPrincipalId string = workload.outputs.managedIdentityPrincipalId
