targetScope = 'resourceGroup'

@description('Name of the existing target ACR in this resource group')
param acrName string

@description('Deterministic container app name used to build stable roleAssignment names')
param containerAppName string

@description('Principal id of the Container App managed identity')
param containerAppPrincipalId string

@description('Principal id of the deployment script managed identity')
param scriptPrincipalId string

var acrPullRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var acrPushRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8311e382-0749-4cb8-b61a-304f252e45ec')

// Existing registry in this resource group
resource targetRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// Grant AcrPull to the container app identity on the registry
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetRegistry.id, containerAppName, 'AcrPull')
  scope: targetRegistry
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: containerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Grant AcrPush to the container app identity on the registry
resource acrPush 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetRegistry.id, containerAppName, 'AcrPush')
  scope: targetRegistry
  properties: {
    roleDefinitionId: acrPushRoleDefinitionId
    principalId: containerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Grant AcrPush to the deployment script identity on the registry
resource scriptAcrPush 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetRegistry.id, 'acrBuildScript', 'AcrPush')
  scope: targetRegistry
  properties: {
    roleDefinitionId: acrPushRoleDefinitionId
    principalId: scriptPrincipalId
    principalType: 'ServicePrincipal'
  }
}
