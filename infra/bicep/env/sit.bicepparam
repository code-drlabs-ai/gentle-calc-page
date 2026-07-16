using '../main.bicep'

// SIT — smallest footprint. Secrets are injected by the pipeline via `az deployment ... -p key=value`
// or a Key Vault reference; the getSecret/readEnvironmentVariable calls below never hard-code them.

param env = 'sit'

param vnetAddressPrefix = '10.10.0.0/16'
param infraSubnetPrefix = '10.10.0.0/23'
param postgresSubnetPrefix = '10.10.2.0/24'

param postgresAdminLogin = 'pgadmin'
// Injected at deploy time — see PIPELINE-SETUP.md, "Provisioning secrets".
param postgresAdminPassword = readEnvironmentVariable('PG_ADMIN_PASSWORD')
param authenticatorPassword = readEnvironmentVariable('PG_AUTHENTICATOR_PASSWORD')

param postgresSkuName = 'Standard_B2s'
param postgresStorageGB = 32
param postgresBackupRetentionDays = 7
param postgresGeoRedundantBackup = false
param postgresZoneRedundantHa = false

param auth0Jwks = readEnvironmentVariable('AUTH0_JWKS')
param auth0Audience = readEnvironmentVariable('AUTH0_AUDIENCE')

param wafMode = 'Prevention'
param apiRateLimitPerMinute = 600
param frontDoorSku = 'Premium_AzureFrontDoor'
param staticWebAppSku = 'Standard'
