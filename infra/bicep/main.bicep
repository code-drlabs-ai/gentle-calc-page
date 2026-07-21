// Orchestrates the full per-environment stack:
//   VNet + private DNS  →  Postgres Flexible Server (private)  →  Log Analytics
//   →  Container Apps (PostgREST)  →  Static Web App  →  Front Door + WAF.
//
// Deploy one resource group per environment (rg-gentlecalc-sit / -uat / -prod) and pass the
// matching param file:
//   az deployment group create -g rg-gentlecalc-sit \
//     -f infra/bicep/main.bicep -p infra/bicep/env/sit.bicepparam
//
// Secrets (DB admin password, authenticator password, Auth0 JWKS) are passed at deploy time
// from the pipeline / Key Vault, never committed. See the param files and PIPELINE-SETUP.md.

targetScope = 'resourceGroup'

@description('Deployment location for regional resources.')
param location string = resourceGroup().location

@description('Short environment name: sit | uat | prod.')
@allowed(['sit', 'uat', 'prod'])
param env string

@description('VNet address space (non-overlapping per environment).')
param vnetAddressPrefix string
param infraSubnetPrefix string
param postgresSubnetPrefix string

@description('Postgres admin login.')
param postgresAdminLogin string

@description('Postgres admin password.')
@secure()
param postgresAdminPassword string

@description('Password for the authenticator role PostgREST connects as.')
@secure()
param authenticatorPassword string

@description('Postgres compute SKU and HA/backup posture.')
param postgresSkuName string = 'Standard_B2s'
param postgresStorageGB int = 32
param postgresBackupRetentionDays int = 14
param postgresGeoRedundantBackup bool = false
param postgresZoneRedundantHa bool = false

@description('Auth0 JWKS document contents.')
@secure()
param auth0Jwks string

@description('Auth0 API identifier (token audience).')
param auth0Audience string

@description('PostgREST container image (pin by digest in prod).')
param postgrestImage string = 'postgrest/postgrest:v12.2.3'

@description('WAF posture.')
param wafMode string = 'Prevention'
param apiRateLimitPerMinute int = 600
param frontDoorSku string = 'Premium_AzureFrontDoor'
param staticWebAppSku string = 'Standard'

// ---- Log Analytics (container logs) ----------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-gentlecalc-${env}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    env: env
    vnetAddressPrefix: vnetAddressPrefix
    infraSubnetPrefix: infraSubnetPrefix
    postgresSubnetPrefix: postgresSubnetPrefix
  }
}

module postgres 'modules/postgres.bicep' = {
  name: 'postgres'
  params: {
    location: location
    env: env
    delegatedSubnetId: network.outputs.postgresSubnetId
    privateDnsZoneId: network.outputs.privateDnsZoneId
    administratorLogin: postgresAdminLogin
    administratorPassword: postgresAdminPassword
    skuName: postgresSkuName
    storageSizeGB: postgresStorageGB
    backupRetentionDays: postgresBackupRetentionDays
    geoRedundantBackup: postgresGeoRedundantBackup
    zoneRedundantHa: postgresZoneRedundantHa
  }
}

module containerApp 'modules/containerapp.bicep' = {
  name: 'containerApp'
  params: {
    location: location
    env: env
    infraSubnetId: network.outputs.infraSubnetId
    logAnalyticsCustomerId: logAnalytics.properties.customerId
    logAnalyticsSharedKey: logAnalytics.listKeys().primarySharedKey
    // authenticator connects over the private FQDN; sslmode=require enforced by the server.
    // The password MUST be percent-encoded: base64 passwords contain / + = which otherwise
    // corrupt the URI authority, making libpq drop the user ("could not look up local user ID 0").
    pgrstDbUri: 'postgres://authenticator:${uriComponent(authenticatorPassword)}@${postgres.outputs.serverFqdn}:5432/${postgres.outputs.databaseName}?sslmode=require'
    auth0Jwks: auth0Jwks
    auth0Audience: auth0Audience
    postgrestImage: postgrestImage
  }
}

module swa 'modules/swa.bicep' = {
  name: 'swa'
  params: {
    location: location
    env: env
    sku: staticWebAppSku
  }
}

module frontDoor 'modules/frontdoor.bicep' = {
  name: 'frontDoor'
  params: {
    location: 'global'
    env: env
    swaHostname: swa.outputs.defaultHostname
    postgrestHostname: containerApp.outputs.postgrestFqdn
    wafMode: wafMode
    apiRateLimitPerMinute: apiRateLimitPerMinute
    skuName: frontDoorSku
  }
}

output frontDoorHostname string = frontDoor.outputs.endpointHostname
output swaName string = swa.outputs.swaName
output postgresServerName string = postgres.outputs.serverName
