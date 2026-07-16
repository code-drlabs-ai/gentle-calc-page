using '../main.bicep'

// UAT — production-like, one size down. Non-overlapping VNet range vs SIT/Prod.

param env = 'uat'

param vnetAddressPrefix = '10.20.0.0/16'
param infraSubnetPrefix = '10.20.0.0/23'
param postgresSubnetPrefix = '10.20.2.0/24'

param postgresAdminLogin = 'pgadmin'
param postgresAdminPassword = readEnvironmentVariable('PG_ADMIN_PASSWORD')
param authenticatorPassword = readEnvironmentVariable('PG_AUTHENTICATOR_PASSWORD')

param postgresSkuName = 'Standard_D2ds_v5'
param postgresStorageGB = 64
param postgresBackupRetentionDays = 14
param postgresGeoRedundantBackup = false
param postgresZoneRedundantHa = false

param auth0Jwks = readEnvironmentVariable('AUTH0_JWKS')
param auth0Audience = readEnvironmentVariable('AUTH0_AUDIENCE')

param wafMode = 'Prevention'
param apiRateLimitPerMinute = 600
param frontDoorSku = 'Premium_AzureFrontDoor'
param staticWebAppSku = 'Standard'
