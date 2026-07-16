using '../main.bicep'

// Production — General Purpose compute with zone-redundant HA and geo-redundant backup.
// Note: zoneRedundantHa REQUIRES a General Purpose / Memory Optimized SKU (not Burstable).

param env = 'prod'

param vnetAddressPrefix = '10.30.0.0/16'
param infraSubnetPrefix = '10.30.0.0/23'
param postgresSubnetPrefix = '10.30.2.0/24'

param postgresAdminLogin = 'pgadmin'
param postgresAdminPassword = readEnvironmentVariable('PG_ADMIN_PASSWORD')
param authenticatorPassword = readEnvironmentVariable('PG_AUTHENTICATOR_PASSWORD')

param postgresSkuName = 'Standard_D4ds_v5'
param postgresStorageGB = 128
param postgresBackupRetentionDays = 35
param postgresGeoRedundantBackup = true
param postgresZoneRedundantHa = true

param auth0Jwks = readEnvironmentVariable('AUTH0_JWKS')
param auth0Audience = readEnvironmentVariable('AUTH0_AUDIENCE')

param wafMode = 'Prevention'
param apiRateLimitPerMinute = 1200
// Pin the image by digest in production. Replace with the digest you have scanned + approved.
param postgrestImage = 'postgrest/postgrest:v12.2.3'
param frontDoorSku = 'Premium_AzureFrontDoor'
param staticWebAppSku = 'Standard'
