targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

// Optional parameters to override the default azd resource naming conventions. Update the main.parameters.json file to provide values. e.g.,:
// "resourceGroupName": {
//      "value": "myGroupName"
// }
param apiServiceName string = ''
param applicationInsightsDashboardName string = ''
param applicationInsightsName string = ''
param appServicePlanName string = ''
param cosmosAccountName string = ''
param cosmosDatabaseName string = ''
param keyVaultName string = ''
param logAnalyticsName string = ''
param resourceGroupName string = ''
param webServiceName string = ''
param apimServiceName string = ''
param connectionStringKey string = 'AZURE-COSMOS-CONNECTION-STRING'
param apimApiName string = 'todo-api'
param apimLoggerName string = 'app-insights-logger'
param collections array = [
  {
    name: 'TodoList'
    id: 'TodoList'
    shardKey: {keys: [
      'Hash'
    ]}
    indexes: [
      {
        key: {
          keys: [
            '_id'
          ]
        }
      }
    ]
  }
  {
    name: 'TodoItem'
    id: 'TodoItem'
    shardKey: {keys: [
      'Hash'
    ]}
    indexes: [
      {
        key: {
          keys: [
            '_id'
          ]
        }
      }
    ]
  }
]

@description('Flag to use Azure API Management to mediate the calls between the Web frontend and the backend API')
param useAPIM bool = false

@description('API Management SKU to use if APIM is enabled')
param apimSku string = 'Consumption'

@description('Id of the user or app to assign application roles')
param principalId string = ''

var abbrs = loadJsonContent('../../../../../../common/infra/bicep/abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var defaultDatabaseName = 'Todo'
var actualDatabaseName = !empty(cosmosDatabaseName) ? cosmosDatabaseName : defaultDatabaseName
var apimApiUri = 'https://${apim.outputs.name}.azure-api.net/todo'
var apimServiceId = useAPIM ? apim.outputs.resourceId : ''

// Organize resources in a resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}

// The application frontend
module web '../../../../../common/infra/bicep/app/web-avm.bicep' = {
  name: 'web'
  scope: rg
  params: {
    name: !empty(webServiceName) ? webServiceName : '${abbrs.webSitesAppService}web-${resourceToken}'
    location: location
    tags: tags
    appServicePlanId: appServicePlan.outputs.resourceId
    appInsightResourceId: applicationInsights.outputs.resourceId
    linuxFxVersion: 'node|20-lts'
  }
}

// The application backend
module api '../../../../../common/infra/bicep/app/api-avm.bicep' = {
  name: 'api'
  scope: rg
  params: {
    name: !empty(apiServiceName) ? apiServiceName : '${abbrs.webSitesAppService}api-${resourceToken}'
    location: location
    tags: tags
    kind: 'app'
    appServicePlanId: appServicePlan.outputs.resourceId
    siteConfig: {
      alwaysOn: true
    }
    appSettings: {
      AZURE_KEY_VAULT_ENDPOINT: keyVault.outputs.uri
      AZURE_COSMOS_CONNECTION_STRING_KEY: connectionStringKey
      AZURE_COSMOS_DATABASE_NAME: actualDatabaseName
      AZURE_COSMOS_ENDPOINT: 'https://${cosmos.outputs.name}.documents.azure.com:443/'
      API_ALLOW_ORIGINS: web.outputs.SERVICE_WEB_URI
      SCM_DO_BUILD_DURING_DEPLOYMENT: true
    }
    appInsightResourceId: applicationInsights.outputs.resourceId
    linuxFxVersion: 'node|20-lts'
    allowedOrigins: [ web.outputs.SERVICE_WEB_URI ]
  }
}

// Give the API access to KeyVault
module accessKeyVault 'br/public:avm/res/key-vault/vault:0.3.5' = {
  name: 'accesskeyvault'
  scope: rg
  params: {
    name: keyVault.outputs.name
    enableRbacAuthorization: false
    enableVaultForDeployment: false
    enableVaultForTemplateDeployment: false
    enablePurgeProtection: false
    sku: 'standard'
    accessPolicies: [
      {
        objectId: principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
      {
        objectId: api.outputs.SERVICE_API_IDENTITY_PRINCIPAL_ID
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
    ]
  }
}

// The application database
module cosmos 'br/public:avm/res/document-db/database-account:0.6.0' = {
  name: 'cosmos'
  scope: rg
  params: {
    locations: [
      {
        failoverPriority: 0
        isZoneRedundant: false
        locationName: location
      }
    ]
    name: !empty(cosmosAccountName) ? cosmosAccountName : '${abbrs.documentDBDatabaseAccounts}${resourceToken}'
    location: location
    mongodbDatabases: [
      {
        name: actualDatabaseName
        tags: tags
        collections: collections
      }
    ]
    secretsExportConfiguration:{
      keyVaultResourceId: keyVault.outputs.resourceId
      primaryWriteConnectionStringSecretName: connectionStringKey
    }
  }
}

// Create an App Service Plan to group applications under the same payment plan and SKU
module appServicePlan 'br/public:avm/res/web/serverfarm:0.1.0' = {
  name: 'appserviceplan'
  scope: rg
  params: {
    name: !empty(appServicePlanName) ? appServicePlanName : '${abbrs.webServerFarms}${resourceToken}'
    sku: {
      name: 'B3'
      tier: 'Basic'
    }
    location: location
    tags: tags
    reserved: true
    kind: 'Linux'
  }
}

// Create a keyvault to store secrets
module keyVault 'br/public:avm/res/key-vault/vault:0.3.5' = {
  name: 'keyvault'
  scope: rg
  params: {
    name: !empty(keyVaultName) ? keyVaultName : '${abbrs.keyVaultVaults}${resourceToken}'
    location: location
    tags: tags
    enableRbacAuthorization: false
    enableVaultForDeployment: false
    enableVaultForTemplateDeployment: false
    enablePurgeProtection: false
    sku: 'standard'
  }
}

// Monitor application with Azure loganalytics
module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.3.4' = {
  name: 'loganalytics'
  scope: rg
  params: {
    name: !empty(logAnalyticsName) ? logAnalyticsName : '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    location: location
  }
}

// Monitor application with Azure applicationInsights
module applicationInsights 'br/public:avm/res/insights/component:0.3.0' = {
  name: 'applicationinsights'
  scope: rg
  params: {
    name: !empty(applicationInsightsName) ? applicationInsightsName : '${abbrs.insightsComponents}${resourceToken}'
    workspaceResourceId: logAnalytics.outputs.resourceId
    location: location
  }
}

// Monitor application with Azure applicationInsightsDashboard
module applicationInsightsDashboard '../../../../../common/infra/bicep/app/applicationinsights-dashboard.bicep' = {
  name: 'application-insights-dashboard'
  scope: rg
  params: {
    name: !empty(applicationInsightsDashboardName) ? applicationInsightsDashboardName : '${abbrs.portalDashboards}${resourceToken}'
    location: location
    applicationInsightsName: applicationInsights.outputs.name
    applicationInsightsId: applicationInsights.outputs.resourceId
  }
}

// Creates Azure API Management (APIM) service to mediate the requests between the frontend and the backend API
module apim 'br/public:avm/res/api-management/service:0.2.0' = if (useAPIM) {
  name: 'apim-deployment'
  scope: rg
  params: {
    name: !empty(apimServiceName) ? apimServiceName : '${abbrs.apiManagementService}${resourceToken}'
    publisherEmail: 'noreply@microsoft.com'
    publisherName: 'n/a'
    location: location
    tags: tags
    sku: apimSku
    skuCount: 0
    customProperties: {}
    zones: []
    apiDiagnostics: [
      {
        apiName: apimApiName
        alwaysLog: 'allErrors'
        backend: {
          request: {
            body: {
              bytes: 1024
            }
          }
          response: {
            body: {
              bytes: 1024
            }
          }
        }
        frontend: {
          request: {
            body: {
              bytes: 1024
            }
          }
          response: {
            body: {
              bytes: 1024
            }
          }
        }
        httpCorrelationProtocol: 'W3C'
        logClientIp: true
        loggerName: apimLoggerName
        metrics: true
        verbosity: 'verbose'
        name: 'applicationinsights'
      }
    ]
    loggers: [
      {
        name: apimLoggerName
        credentials: {
          instrumentationKey: applicationInsights.outputs.instrumentationKey
        }
        loggerDescription: 'Logger to Azure Application Insights'
        isBuffered: false
        loggerType: 'applicationInsights'
        targetResourceId: applicationInsights.outputs.resourceId
      }
    ]
    apis: [
      {
        name: apimApiName
        path: 'todo'
        displayName: 'Simple Todo API'
        apiDescription: 'This is a simple Todo API'
        serviceUrl: api.outputs.SERVICE_API_URI
        subscriptionRequired: false
        protocols: [ 'https' ]
        type: 'http'
        value: loadTextContent('../../../../../api/common/openapi.yaml')
        policies: [
          {
            value: replace(loadTextContent('../../../../../../common/infra/shared/gateway/apim/apim-api-policy.xml'), '{origin}', web.outputs.SERVICE_WEB_URI)
            format: 'rawxml'
          }
        ]
      }
    ]
  }
}

//Configures the API settings for an api app within the Azure API Management (APIM) service.
module apiConfig 'br/public:avm/res/web/site:0.3.9' = if (useAPIM) {
  name: 'apiconfig'
  scope: rg
  params: {
    kind: 'app'
    name: api.outputs.SERVICE_API_NAME
    tags: union(tags, { 'azd-service-name': 'api' })
    serverFarmResourceId: appServicePlan.outputs.resourceId
    location: location
    apiManagementConfiguration: {
      apiManagementConfig: {
        id: '${apimServiceId}/apis/${apimApiName}'
      }
    }
  }
}

// Data outputs
output AZURE_COSMOS_CONNECTION_STRING_KEY string = connectionStringKey
output AZURE_COSMOS_DATABASE_NAME string = actualDatabaseName

// App outputs
output APPLICATIONINSIGHTS_CONNECTION_STRING string = applicationInsights.outputs.connectionString
output AZURE_KEY_VAULT_ENDPOINT string = keyVault.outputs.uri
output AZURE_KEY_VAULT_NAME string = keyVault.outputs.name
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output API_BASE_URL string = useAPIM ? apimApiUri : api.outputs.SERVICE_API_URI
output REACT_APP_WEB_BASE_URL string = web.outputs.SERVICE_WEB_URI
output USE_APIM bool = useAPIM
output SERVICE_API_ENDPOINTS array = useAPIM ? [ apimApiUri, api.outputs.SERVICE_API_URI ]: []
