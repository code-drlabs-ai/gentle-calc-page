// Azure Front Door Standard/Premium + WAF, the single public entry point.
//
// Two origin groups:
//   - the Static Web App (React), served at the site root.
//   - the PostgREST Container App, served under /rest/v1/*.
// A WAF policy (managed rules + a rate limit on the API path) is associated with the
// endpoint. Front Door terminates TLS and is where the security headers / rate limiting
// live at the edge, in front of both origins.

@description('Deployment location for the profile (Front Door is global; this is metadata).')
param location string = 'global'

@description('Short environment name, e.g. sit | uat | prod.')
param env string

@description('Default hostname of the Static Web App origin (no scheme).')
param swaHostname string

@description('FQDN of the PostgREST Container App origin (no scheme).')
param postgrestHostname string

@description('WAF mode. Use Prevention for real environments; Detection only while tuning.')
@allowed(['Prevention', 'Detection'])
param wafMode string = 'Prevention'

@description('Requests allowed per minute per client IP on /rest/v1/*.')
param apiRateLimitPerMinute int = 600

@description('Front Door SKU. Premium adds managed rules + private-link origins.')
@allowed(['Standard_AzureFrontDoor', 'Premium_AzureFrontDoor'])
param skuName string = 'Premium_AzureFrontDoor'

var profileName = 'afd-gentlecalc-${env}'
var endpointName = 'gentlecalc-${env}'
var wafPolicyName = 'wafgentlecalc${env}'

resource profile 'Microsoft.Cdn/profiles@2024-09-01' = {
  name: profileName
  location: location
  sku: {
    name: skuName
  }
}

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-09-01' = {
  parent: profile
  name: endpointName
  location: location
  properties: {
    enabledState: 'Enabled'
  }
}

// ---- Origin group + origin: Static Web App (site root) ----------------------
resource swaOriginGroup 'Microsoft.Cdn/profiles/originGroups@2024-09-01' = {
  parent: profile
  name: 'og-swa'
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
    }
    healthProbeSettings: {
      probePath: '/'
      probeRequestType: 'HEAD'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 100
    }
  }
}

resource swaOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2024-09-01' = {
  parent: swaOriginGroup
  name: 'swa'
  properties: {
    hostName: swaHostname
    originHostHeader: swaHostname
    httpsPort: 443
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
  }
}

// ---- Origin group + origin: PostgREST (API) ---------------------------------
resource apiOriginGroup 'Microsoft.Cdn/profiles/originGroups@2024-09-01' = {
  parent: profile
  name: 'og-postgrest'
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
    }
    healthProbeSettings: {
      probePath: '/'
      probeRequestType: 'GET'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 100
    }
  }
}

resource apiOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2024-09-01' = {
  parent: apiOriginGroup
  name: 'postgrest'
  properties: {
    hostName: postgrestHostname
    originHostHeader: postgrestHostname
    httpsPort: 443
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
  }
}

// ---- Routes -----------------------------------------------------------------
// API route first (more specific path). PostgREST expects paths without the /rest/v1
// prefix, so strip it before forwarding.
resource apiRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-09-01' = {
  parent: endpoint
  name: 'route-api'
  dependsOn: [apiOrigin]
  properties: {
    originGroup: {
      id: apiOriginGroup.id
    }
    patternsToMatch: ['/rest/v1/*']
    forwardingProtocol: 'HttpsOnly'
    supportedProtocols: ['Https']
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
    ruleSets: [
      {
        id: apiRuleSet.id
      }
    ]
  }
}

resource swaRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-09-01' = {
  parent: endpoint
  name: 'route-swa'
  dependsOn: [swaOrigin]
  properties: {
    originGroup: {
      id: swaOriginGroup.id
    }
    patternsToMatch: ['/*']
    forwardingProtocol: 'HttpsOnly'
    supportedProtocols: ['Https']
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
  }
}

// Strip the /rest/v1 prefix before the request reaches PostgREST.
resource apiRuleSet 'Microsoft.Cdn/profiles/ruleSets@2024-09-01' = {
  parent: profile
  name: 'apirules'
}

resource stripPrefixRule 'Microsoft.Cdn/profiles/ruleSets/rules@2024-09-01' = {
  parent: apiRuleSet
  name: 'stripRestV1'
  properties: {
    order: 1
    actions: [
      {
        name: 'UrlRewrite'
        parameters: {
          typeName: 'DeliveryRuleUrlRewriteActionParameters'
          sourcePattern: '/rest/v1/'
          destination: '/'
          preserveUnmatchedPath: true
        }
      }
    ]
  }
}

// ---- WAF policy + security policy ------------------------------------------
resource waf 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2024-02-01' = {
  name: wafPolicyName
  location: location
  sku: {
    name: skuName
  }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      mode: wafMode
      requestBodyCheck: 'Enabled'
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: '2.1'
          ruleSetAction: 'Block'
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '1.0'
        }
      ]
    }
    customRules: {
      rules: [
        {
          name: 'apiRateLimit'
          priority: 1
          enabledState: 'Enabled'
          ruleType: 'RateLimitRule'
          rateLimitDurationInMinutes: 1
          rateLimitThreshold: apiRateLimitPerMinute
          matchConditions: [
            {
              matchVariable: 'RequestUri'
              operator: 'Contains'
              matchValue: ['/rest/v1/']
              transforms: ['Lowercase']
            }
          ]
          action: 'Block'
        }
      ]
    }
  }
}

resource securityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2024-09-01' = {
  parent: profile
  name: 'sp-waf'
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: {
        id: waf.id
      }
      associations: [
        {
          domains: [
            {
              id: endpoint.id
            }
          ]
          patternsToMatch: ['/*']
        }
      ]
    }
  }
}

output endpointHostname string = endpoint.properties.hostName
output profileName string = profile.name
