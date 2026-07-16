// Azure Database for PostgreSQL Flexible Server, VNet-integrated with NO public access.
//
// The server is reachable only from inside the VNet (the Container Apps subnet). There is
// no public endpoint and no firewall allow-list — the database is genuinely internal.
// PITR and Defender come from the platform; backups are managed.

@description('Deployment location.')
param location string

@description('Short environment name, e.g. sit | uat | prod.')
param env string

@description('Resource id of the delegated Postgres subnet.')
param delegatedSubnetId string

@description('Resource id of the privatelink.postgres private DNS zone.')
param privateDnsZoneId string

@description('Administrator login name.')
param administratorLogin string

@description('Administrator password. Pass from a secure source (Key Vault / pipeline secret); never hard-code.')
@secure()
param administratorPassword string

@description('Postgres major version.')
param postgresVersion string = '16'

@description('Compute SKU. Default is a small burstable tier; raise for Production.')
param skuName string = 'Standard_B2s'

@description('Storage in GB.')
param storageSizeGB int = 32

@description('Backup retention in days.')
@minValue(7)
@maxValue(35)
param backupRetentionDays int = 14

@description('Enable geo-redundant backup (recommended for Production).')
param geoRedundantBackup bool = false

@description('Enable zone-redundant HA. Requires a General Purpose or Memory Optimized SKU (not Burstable). Set true for Production with a matching skuName.')
param zoneRedundantHa bool = false

var serverName = 'psql-gentlecalc-${env}'
var databaseName = 'appdb'

resource flex 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: serverName
  location: location
  sku: {
    name: skuName
    tier: startsWith(skuName, 'Standard_B') ? 'Burstable' : 'GeneralPurpose'
  }
  properties: {
    version: postgresVersion
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    storage: {
      storageSizeGB: storageSizeGB
    }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: geoRedundantBackup ? 'Enabled' : 'Disabled'
    }
    // Private access: bound to the delegated subnet, no public endpoint.
    network: {
      delegatedSubnetResourceId: delegatedSubnetId
      privateDnsZoneArmResourceId: privateDnsZoneId
      publicNetworkAccess: 'Disabled'
    }
    highAvailability: {
      mode: zoneRedundantHa ? 'ZoneRedundant' : 'Disabled'
    }
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: flex
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// Require TLS for every connection.
resource requireSsl 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: flex
  name: 'require_secure_transport'
  properties: {
    value: 'on'
    source: 'user-override'
  }
}

output serverName string = flex.name
output serverFqdn string = flex.properties.fullyQualifiedDomainName
output databaseName string = database.name
