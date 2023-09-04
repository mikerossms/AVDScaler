//build the An Automation Account (requires LAW ID)

//NOTE: Could do with fleshing out the Runbook section to include actual content.

//PARAMETERS
@description('Required - Tags for the deployed resources')
param tags object

@description('Geographic Location of the Resources.')
param location string = resourceGroup().location

@description('Optional - ID of the Log Analytics service to send debug info to.  Default: none')
param lawID string = ''

@description('Required - Name of the Automation Account resource')
param aaName string

@description('Optional - A list of runbook objects to create within the automation account.  Default: none')
param aaRunbooks array = []

@description('Optional - A list of runbook variables to create within the automation account.  Default: none')
param aaVariables array = []

@description('Optional - Defined User Assigned ID object - Default: SystemAssigned')
param userAssignedID object = {
  type: 'SystemAssigned'
}

@description('Optional - Automation Account SKU.  Default: Basic')
@allowed([
  'Basic'
  'Free'
])
param aaSku string = 'Basic'

@description('Optional - whether to disable local authentication or not.  Default: true (disable it)')
param disableLocalAuth bool = true

@description('Optional - Enable public network access to the AA account.  Default: false (disable it)')
param enablePublicNetworkAccess bool = false

@description('Optional - Whether to deploy a private endpoint for webhooks etc.  Default: false (backward compatability)')
param deployPrivateEndpoint bool = false

@description('Optional - Specifies the type of Key Source to use.  Default: Microsoft.Automation')
@allowed([
  'Microsoft.Automation'
  'Microsoft.Keyvault'
])
param keySource string = 'Microsoft.Automation'

@description('Optional - The Key Vault properties if using Key Soruce of Keyvault.  Default: {}')
param keyVaultProperties object = {}


@description('Network config for Private endpoint (Common Config->vnet->localenv)  Required if deployPrivateEndpoint is True')
param vnetConfig object = {
  vnetName: ''
}

@description('Subnet to deploy endpoint.  Required if deployPrivateEndpoint is True')
param endpointSnetName string = ''

@description('Optional/Required - DNS config for the local environment where an endpoint is to be added.  Required if deploying an endpoint  Default: {}')
param dnsConfig object = {}

@description('Optional - Deploy the DNS record.  Default: true')
param deployDNSRecord bool = true

//VARIABLES
var aaDiagName = '${aaName}__diag'
var aaPepName = '${aaName}-pep-${vnetConfig.vnetName}-${endpointSnetName}'


//Create the Automation account
resource AutomationAccount 'Microsoft.Automation/automationAccounts@2021-06-22' = {
  tags: tags
  location: location
  name: aaName
  identity: userAssignedID
  properties: {
    sku: {
      name: aaSku
    }
    disableLocalAuth: disableLocalAuth
    publicNetworkAccess: enablePublicNetworkAccess
    encryption: {
      keySource: keySource
      keyVaultProperties: empty(keyVaultProperties) ? json('null') : keyVaultProperties
    }
  }
}

//Add runbooks if specified
resource AutomationAccountRunbook 'Microsoft.Automation/automationAccounts/runbooks@2019-06-01' = [ for (rbObject,i) in aaRunbooks: {
  tags: tags
  location: location
  name: rbObject.aaRunbookName
  parent: AutomationAccount
  properties: {
    runbookType: rbObject.aaRunBookType
    description: rbObject.aaRunBookDescription
  }
}]

//Add variables if specified
resource AutomationAccountVariables 'Microsoft.Automation/automationAccounts/variables@2019-06-01' = [ for (varObject,i) in aaVariables: {
  name: varObject.aaVarName
  parent: AutomationAccount
  properties: {
    value: '"${varObject.aaVarValue}"'
    description: varObject.aaVarDescription
  }
}]

// //Create the Private Endpoint for the AA account (and associated runbooks)
// module AAPrivateEndpoint 'privateEndpoint.bicep' = if (deployPrivateEndpoint) {
//   name: 'vaultPrivateEndpoint'
//   params: {
//     tags: tags
//     location: location
//     privateEndpointName: aaPepName
//     dnsName: deployDNSRecord ? AutomationAccount.name : ''
//     dnsConfig: dnsConfig
//     vnetConfig: vnetConfig
//     endpointSnetName: endpointSnetName
//     serviceType: 'automation'
//     serviceID: AutomationAccount.id

//   }
// }


//Add diagnostics logging
resource automation_account_diagnostic 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (lawID != '') {
  name: aaDiagName
  scope: AutomationAccount
  properties: {
    workspaceId: lawID
    logs: [
      {
        category: 'JobLogs'
        enabled: true
      }
    ]
  }
}

output AAID string = AutomationAccount.id
