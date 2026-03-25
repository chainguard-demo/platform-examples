targetScope = 'resourceGroup'

@description('Azure region for the deployment.')
param location string

@description('Base name used to derive Azure resource names.')
param workloadName string

@description('Container image for the service, including registry and tag.')
param containerImage string

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
          image: containerImage
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

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetRegistry.id, containerApp.name, 'AcrPull')
  scope: targetRegistry
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: containerApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource acrPush 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetRegistry.id, containerApp.name, 'AcrPush')
  scope: targetRegistry
  properties: {
    roleDefinitionId: acrPushRoleDefinitionId
    principalId: containerApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output containerAppName string = containerApp.name
output serviceUrl string = externalIngress ? 'https://${containerApp.properties.configuration.ingress.fqdn}' : ''
output managedIdentityPrincipalId string = containerApp.identity.principalId
