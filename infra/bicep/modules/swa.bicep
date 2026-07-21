// Azure Static Web App for the React SPA. The GitHub Actions workflow deploys the built
// bundle with a deployment token; this module provisions the resource and (optionally) a
// custom domain. Standard SKU is required for custom domains + enterprise-grade features.

@description('Deployment location. SWA is available in a limited set of regions.')
param location string = 'westeurope'

@description('Short environment name, e.g. sit | uat | prod.')
param env string

@description('SKU: Free for throwaway, Standard for real environments.')
@allowed(['Free', 'Standard'])
param sku string = 'Free'

var swaName = 'swa-gentlecalc-${env}'

resource swa 'Microsoft.Web/staticSites@2024-04-01' = {
  name: swaName
  location: location
  sku: {
    name: sku
    tier: sku
  }
  properties: {
    // The app is built and pushed by CI (skip_app_build), not built by Oryx here.
    buildProperties: {
      skipGithubActionWorkflowGeneration: true
    }
    // Do not expose the default *.azurestaticapps.net host to config drift; we front it
    // with Front Door and bind the custom domain there.
    allowConfigFileUpdates: true
  }
}

output swaName string = swa.name
output defaultHostname string = swa.properties.defaultHostname
