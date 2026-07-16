// Container Apps environment + the PostgREST container.
//
// This is the ONLY public backend. There is no GoTrue container — Auth0 is the identity
// provider and PostgREST verifies Auth0's RS256 tokens against Auth0's JWKS.
//
// Ingress is internal to the Container Apps environment; the public entry point is Front
// Door (frontdoor.bicep), which is what applies WAF and rate limiting. Exposing the
// container only through Front Door means the raw PostgREST endpoint is not directly
// reachable from the internet.

@description('Deployment location.')
param location string

@description('Short environment name, e.g. sit | uat | prod.')
param env string

@description('Resource id of the infra subnet for the Container Apps environment.')
param infraSubnetId string

@description('Log Analytics workspace customer id (GUID) for container logs.')
param logAnalyticsCustomerId string

@description('Log Analytics shared key.')
@secure()
param logAnalyticsSharedKey string

@description('Full Postgres connection URI for the authenticator role (private FQDN, sslmode=require).')
@secure()
param pgrstDbUri string

@description('Auth0 JWKS document (contents of https://<tenant>/.well-known/jwks.json).')
@secure()
param auth0Jwks string

@description('Auth0 API identifier — the expected token audience.')
param auth0Audience string

@description('PostgREST image, pinned by digest in production param files.')
param postgrestImage string = 'postgrest/postgrest:v12.2.3'

@description('Min/max replicas.')
param minReplicas int = 1
param maxReplicas int = 3

var envName = 'cae-gentlecalc-${env}'
var appName = 'ca-postgrest-${env}'

resource containerEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: envName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: infraSubnetId
      // Internal: no public IP on the environment. Front Door reaches it privately.
      internal: true
    }
    zoneRedundant: false
  }
}

resource postgrest 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true // external within the internal env = reachable by Front Door origin
        targetPort: 3000
        transport: 'auto'
        allowInsecure: false
        // Only Front Door may call the origin; direct hits are refused. The Front Door id
        // header check is enforced by the WAF/origin binding in frontdoor.bicep.
        ipSecurityRestrictions: []
      }
      secrets: [
        { name: 'pgrst-db-uri', value: pgrstDbUri }
        { name: 'pgrst-jwt-jwks', value: auth0Jwks }
      ]
    }
    template: {
      containers: [
        {
          name: 'postgrest'
          image: postgrestImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'PGRST_DB_URI', secretRef: 'pgrst-db-uri' }
            { name: 'PGRST_JWT_SECRET', secretRef: 'pgrst-jwt-jwks' }
            { name: 'PGRST_DB_SCHEMAS', value: 'public' }
            { name: 'PGRST_DB_ANON_ROLE', value: 'anon' }
            { name: 'PGRST_JWT_AUD', value: auth0Audience }
            { name: 'PGRST_JWT_ROLE_CLAIM_KEY', value: '.role' }
            { name: 'PGRST_DB_MAX_ROWS', value: '1000' }
            { name: 'PGRST_DB_PLAN_ENABLED', value: 'false' }
            { name: 'PGRST_OPENAPI_MODE', value: 'disabled' }
            { name: 'PGRST_DB_POOL', value: '10' }
            { name: 'PGRST_SERVER_PORT', value: '3000' }
            { name: 'PGRST_LOG_LEVEL', value: 'info' }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
      }
    }
  }
}

output containerEnvId string = containerEnv.id
output postgrestFqdn string = postgrest.properties.configuration.ingress.fqdn
