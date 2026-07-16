// VNet with two delegated subnets and a private DNS zone for Postgres Flexible Server.
//
// Subnet split:
//   - infra subnet: the Container Apps managed environment (needs a dedicated subnet).
//   - postgres subnet: delegated to Flexible Server; the DB lives here with no public access.
// The private DNS zone resolves the Flex server's FQDN to its private address, so PostgREST
// reaches the database entirely inside the VNet.

@description('Deployment location.')
param location string

@description('Short environment name, e.g. sit | uat | prod.')
param env string

@description('Address space for the VNet. Give each environment a non-overlapping range.')
param vnetAddressPrefix string = '10.10.0.0/16'

@description('Subnet prefix for the Container Apps environment (needs at least /23).')
param infraSubnetPrefix string = '10.10.0.0/23'

@description('Subnet prefix for the delegated Postgres subnet.')
param postgresSubnetPrefix string = '10.10.2.0/24'

var vnetName = 'vnet-gentlecalc-${env}'
var privateDnsZoneName = 'privatelink.postgres.database.azure.com'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: 'snet-infra'
        properties: {
          addressPrefix: infraSubnetPrefix
        }
      }
      {
        name: 'snet-postgres'
        properties: {
          addressPrefix: postgresSubnetPrefix
          delegations: [
            {
              name: 'flexibleServers'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
    ]
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
}

resource dnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

output vnetId string = vnet.id
output infraSubnetId string = vnet.properties.subnets[0].id
output postgresSubnetId string = vnet.properties.subnets[1].id
output privateDnsZoneId string = privateDnsZone.id
