targetScope = 'resourceGroup'

@description('Azure region for the deployment.')
param location string

@description('Base name used to derive Azure resource names.')
param workloadName string

// The container image is built into the target ACR before deployment using
// `az acr build --registry <acrName> --image cgr-image-copy:v1`. The runtime
// image used by the Container App is `cgr-image-copy:v1` in the target ACR.

@description('CPU requested by the Container App.')
param containerCpu string

@description('Memory requested by the Container App.')
param containerMemory string

@description('Port exposed by the service.')
param containerPort int

@description('Name of the existing target Azure Container Registry.')
param acrName string

@description('Resource group that contains the target Azure Container Registry.')
param acrResourceGroupName string

@description('Destination repository prefix in ACR, including registry host.')
param dstRepoPrefix string

@description('Path to the Dockerfile to use when building the runtime image.')
param dockerfilePath string = 'Dockerfile'

@description('UTC tag used to force deploymentScript update and rerun when changed.')
param utcValue string = utcNow()

@description('Chainguard issuer URL.')
param issuerUrl string

@description('Chainguard API endpoint.')
param apiEndpoint string

@description('Chainguard source group name.')
param groupName string

@description('Chainguard source group ID.')
param groupId string

@description('Chainguard identity ID used by the service.')
param identityId string

@secure()
@description('Bootstrap OIDC token required by the current app code path for Chainguard token exchange.')
param chainguardOidcToken string

@description('Skip referrer tags such as signatures and attestations.')
param ignoreReferrers bool

@description('Verify signatures before copying an image.')
param verifySignatures bool

@description('Apply external ingress to the Container App.')
param externalIngress bool

@description('Tags applied to created Azure resources.')
param tags object

var containerAppName = '${workloadName}-app'
var managedEnvironmentName = '${workloadName}-env'
var workspaceName = '${workloadName}-logs'
var keyVaultName = '${workloadName}-kv'
var acrPullRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var acrPushRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8311e382-0749-4cb8-b61a-304f252e45ec')
var secrets = empty(chainguardOidcToken) ? [] : [
  {
    name: 'chainguard-oidc-token'
    value: chainguardOidcToken
  }
]
var envVars = concat([
  {
    name: 'ISSUER_URL'
    value: issuerUrl
  }
  {
    name: 'API_ENDPOINT'
    value: apiEndpoint
  }
  {
    name: 'GROUP_NAME'
    value: groupName
  }
  {
    name: 'GROUP'
    value: groupId
  }
  {
    name: 'IDENTITY'
    value: identityId
  }
  {
    name: 'DST_REPO'
    value: dstRepoPrefix
  }
  {
    name: 'ACR_REGISTRY'
    value: targetRegistry.properties.loginServer
  }
  {
    name: 'IGNORE_REFERRERS'
    value: string(ignoreReferrers)
  }
  {
    name: 'VERIFY_SIGNATURES'
    value: string(verifySignatures)
  }
  {
    name: 'PORT'
    value: string(containerPort)
  }
], empty(chainguardOidcToken) ? [] : [
  {
    name: 'OIDC_TOKEN'
    secretRef: 'chainguard-oidc-token'
  }
])

// Compute the effective container image if the caller did not supply one.
// If `dstRepoPrefix` already includes the loginServer, preserve it; otherwise
// build using the target registry login server.
var repoPrefix = startsWith(dstRepoPrefix, targetRegistry.properties.loginServer) ? dstRepoPrefix : '${targetRegistry.properties.loginServer}/${dstRepoPrefix}'
// The build workflow places `cgr-image-copy:v1` in the registry; use that
// explicit image name so deployments are deterministic.
var effectiveContainerImage = '${targetRegistry.properties.loginServer}/cgr-image-copy:v1'

resource targetRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  scope: resourceGroup(subscription().subscriptionId, acrResourceGroupName)
  name: acrName
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: managedEnvironmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspace.properties.customerId
        sharedKey: listKeys(workspace.id, workspace.apiVersion).primarySharedKey
      }
    }
  }
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: externalIngress
        targetPort: containerPort
        transport: 'auto'
      }
      registries: [
        {
          server: targetRegistry.properties.loginServer
          identity: 'system'
        }
      ]
      secrets: secrets
    }
    template: {
      containers: [
        {
          name: 'image-copy-acr'
          image: effectiveContainerImage
          env: envVars
          resources: {
            cpu: json(containerCpu)
            memory: containerMemory
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// Role assignments and deployment script for the target ACR are created at
// The deployment script is created in this resource-group-scoped module so
// it runs in the workload resource group. The role assignments themselves
// are created in the ACR resource group's scope by a separate module.
resource acrBuildScript 'Microsoft.Resources/deploymentScripts@2023-01-01' = {
  name: '${workloadName}-acrBuild'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    forceUpdateTag: utcValue
    azCliVersion: '2.42.0'
    timeout: 'PT30M'
    scriptContent: 'az acr build --registry ${acrName} --image cgr-image-copy:v1 --file ${dockerfilePath} .'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
  }
}

// Key Vault for holding sensitive values (static name). This deployment
// creates a placeholder secret; operators should replace the value with
// real secrets after deployment.
resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: containerApp.identity.principalId
        permissions: {
          secrets: [
            'get'
          ]
        }
      }
    ]
    enableSoftDelete: true
  }
  dependsOn: [ containerApp ]
}

resource kvSecret 'Microsoft.KeyVault/vaults/secrets@2022-07-01' = {
  name: '${keyVault.name}/chainguard-oidc-token'
  properties: {
    value: 'REPLACE_ME'
  }
  dependsOn: [ keyVault ]
}

output containerAppName string = containerApp.name
output serviceUrl string = externalIngress ? 'https://${containerApp.properties.configuration.ingress.fqdn}' : ''
output managedIdentityPrincipalId string = containerApp.identity.principalId
output buildScriptPrincipalId string = acrBuildScript.identity.principalId
output keyVaultName string = keyVault.name
output keyVaultUri string = 'https://${keyVault.name}.vault.azure.net/'
