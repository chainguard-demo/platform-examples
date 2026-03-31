using './main.bicep'

param containerRegistryName = 'myuniquecgrregistry'
param acrResourceGroupName = ''
param gitRepoUrl = 'https://github.com/justinprince/platform-examples'
param gitRepoBranch = 'main'
param dockerfilePath = 'Dockerfile'
param gitRepoContextPath = 'claude-image-copy-acr-blueprint'
param chainguardOidcToken = 'REPLACE_WITH_CHAINCTL_OIDC_TOKEN'
