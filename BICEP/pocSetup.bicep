//A quite and dirty POC setup to test the EHP scaler
/*Deploys:
 - log analytics
 - keyvault (for vmss admin username and password)
 - vnet + subnet
 - hostpool, workspace, appgroup - key set to 30 days
 - vmss with standard windows 10 multisession image
 - host pool integration extension
*/

//This bicep will run in RG mode (rather than subscription) - it will therefore need to be deployed to an existing RG
targetScope = 'resourceGroup'

//PARAMETERS
@description('The localenv identifier.')
@allowed([
  'dev'
  'prod'
])
param localenv string

@description('Location of the Resources.')
param location string = 'uksouth'

param tags object = {
  Environment: toUpper(localenv)
}

param product string = 'ehppoc'

param lawName string = '${product}-law-${localenv}'

//!!!CONFIG!!!
param vnetDetails object = {
  name: '${product}-vnet-${localenv}'
  vnetPrefix: '10.249.0.0/24'
  subnetName: '${product}-subnet-${localenv}'
  subnetPrefix: '10.249.0.0/26'
  nsgName: '${product}-nsg-${localenv}'
}

@description('Get the current time and date in UTC format')
param currentTime string = utcNow('u')

@description('Number of VMs to add to the pool')
param vmssHostInstances int = 1

@description('The size of the virtual machine to build')
param vmssSize string = 'Standard_B2s'

@description('URL of the Artifacts script required to join VMSS to HP')
param artifactsLocation string ='https://wvdportalstorageblob.blob.${environment().suffixes.storage}/galleryartifacts/'


@description('The admin user name for the VMSS')
param adminUsername string = 'poctest'


//Create a pseudorandom password - this is NOT a secure way of doing this - it is for POC only
param guidValue string = newGuid()
var adminPassword = '${toUpper(uniqueString(resourceGroup().id))}-${guidValue}'


//VARIABLES
var hostPoolName = toLower('${product}-hp-${localenv}')
var appGroupName = toLower('${product}-dag-${localenv}')
var workspaceName = toLower('${product}-ws-${localenv}')
var vmssName = toLower('${product}-vmss-${localenv}')
var keyVaultName = toLower('${product}-kv-${localenv}')

var tokenLength = 'P30D'
var tokenExpirationTime = dateTimeAdd(currentTime,tokenLength)


//Create Log analytics
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2021-06-01' = {
  name: lawName
  location: location
  tags: tags
  properties: {
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

//Create the KeyVault
resource Vault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    enabledForDeployment: false
    enabledForTemplateDeployment: false
    enabledForDiskEncryption: false
    enableRbacAuthorization: true
    enableSoftDelete: false
    tenantId: tenant().tenantId
    sku: {
      name: 'standard'
      family: 'A'
    }
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

//Add the VMSS admin password to the keyvault
resource VMSSAdmPwd 'Microsoft.KeyVault/vaults/secrets@2022-07-01' = {
  parent: Vault
  name: 'vmssPwd'
  properties: {
    contentType: 'string'
    value: adminPassword
    attributes: {
      enabled: true
    }
  }
}

//Add the VMSS admin password to the keyvault
resource VMSSAdmUser 'Microsoft.KeyVault/vaults/secrets@2022-07-01' = {
  parent: Vault
  name: 'vmssUser'
  properties: {
    contentType: 'string'
    value: adminUsername
    attributes: {
      enabled: true
    }
  }
}

resource VaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: Vault
  name: '${keyVaultName}-kv-diagnostics'
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'AuditEvent'
        enabled: true
        retentionPolicy: {
          days: 14
          enabled: true
        }
      }
      {
        category: 'AzurePolicyEvaluationDetails'
        enabled: true
        retentionPolicy: {
          days: 14
          enabled: true
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          days: 14
          enabled: true
        }
      }
    ]
  }
}


//Create the NSG
resource NSG 'Microsoft.Network/networkSecurityGroups@2022-05-01'  = {
  name: vnetDetails.nsgName
  location: location
  tags: tags
}

//Set up the vnet (deploy if new deployment only)
resource VNet 'Microsoft.Network/virtualNetworks@2020-06-01' = {
  name: vnetDetails.name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetDetails.vnetPrefix
      ]
    }

    //subnets pulled out into its own resource
    subnets: [{
      name: vnetDetails.subnetName
      properties: {
        networkSecurityGroup: {
          location: location
          id: NSG.id
        }
        addressPrefix: vnetDetails.subnetPrefix
        privateEndpointNetworkPolicies: 'Disabled'
      }
    }]
  }
}


//VNET Diagnostics
resource vnetDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: VNet
  name: '${vnetDetails.name}-diagnostics'
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'VMProtectionAlerts'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
    ]
  }
}

//NSG Diagnostics
resource NSGDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview'  = {
  scope: NSG
  name: '${vnetDetails.nsgName}-diagnostics'
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'NetworkSecurityGroupEvent'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
      {
        category: 'NetworkSecurityGroupRuleCounter'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
    ]
  }
}

//Create the Host Pool
resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2022-04-01-preview' = {
  name: hostPoolName
  location: location
  tags: tags
  properties: {
    description: 'Hostpool for EHP POC'
    hostPoolType: 'Pooled'
    loadBalancerType: 'BreadthFirst'
    preferredAppGroupType: 'Desktop'
    maxSessionLimit: 4
    validationEnvironment: false
    registrationInfo: {
      expirationTime: tokenExpirationTime
      token: null
      registrationTokenOperation: 'Update'
    }
    
  }
}


resource applicationGroup 'Microsoft.DesktopVirtualization/applicationGroups@2019-12-10-preview' = {
  name: appGroupName
  location: location
  tags: tags
  properties: {
    applicationGroupType: 'Desktop'
    description: 'Core License Service Application Group'
    hostPoolArmPath: resourceId('Microsoft.DesktopVirtualization/hostpools', hostPoolName)
  }
  dependsOn: [
    hostPool
  ]
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2019-12-10-preview' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    description: 'Workspace created for ${hostPoolName} Host Pool'
    applicationGroupReferences: [
      applicationGroup.id
    ]
  }
}


//Log analytics diagnostic settings - Hostpool
resource diagHostPoolDiagnostics 'Microsoft.Insights/diagnosticSettings@2017-05-01-preview' = {
  scope: hostPool
  name: 'diagnosticSettings'
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'Checkpoint'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
      {
        category: 'Error'
        enabled: true
        retentionPolicy: {
          days: 30
          enabled: true
        }
      }
      {
        category: 'Management'
        enabled: true
        retentionPolicy: {
          days: 14
          enabled: true
        }
      }
      {
        category: 'Connection'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
      {
        category: 'HostRegistration'
        enabled: true
        retentionPolicy: {
          days: 30
          enabled: true
        }
      }
      {
        category: 'AgentHealthStatus'
        enabled: true
        retentionPolicy: {
          days: 30
          enabled: true
        }
      }
    ]
  }
}

//Log analytics diagnostic settings - Hostpool
resource diagHostPoolWorkspaceDiagnostics 'Microsoft.Insights/diagnosticSettings@2017-05-01-preview' = {
  scope: workspace
  name: 'diagnosticSettings'
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'Checkpoint'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
      {
        category: 'Error'
        enabled: true
        retentionPolicy: {
          days: 30
          enabled: true
        }
      }
      {
        category: 'Management'
        enabled: true
        retentionPolicy: {
          days: 14
          enabled: true
        }
      }
      {
        category: 'Feed'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
    ]
  }
}

//Create the VMSS
//Build the scale set
resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2022-08-01' = {
  name: vmssName
  location: location
  tags: tags
  sku: {
    name: vmssSize
    tier: 'standard'
    capacity: vmssHostInstances
  }
  properties: {
    overprovision: false
    upgradePolicy: {
      mode: 'Automatic'
    }
    virtualMachineProfile: {
      storageProfile: {
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadWrite'
        }
        imageReference: {
          offer: 'windows-10'
          publisher: 'MicrosoftWindowsDesktop'
          sku: 'win10-21h2-avd'
          version: 'latest'
        }
        dataDisks: []
      }
      osProfile: {
        computerNamePrefix: 'ehp'
        adminUsername: adminUsername
        adminPassword: adminPassword

      }

      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: 'nic'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'ipconfig'
                  properties: {
                    subnet: {
                      id: VNet.properties.subnets[0].id
                    }
                  }
                }
              ]
            }
          }
        ]
      }
    }
  }
}

//Re-call the host pool in order to pull out the token (it is null if you call it on the original object)
resource hpReload 'Microsoft.DesktopVirtualization/hostPools@2021-01-14-preview' existing = {
  name: hostPoolName
}

//Add VMSS to host pool
resource dscextension 'Microsoft.Compute/virtualMachineScaleSets/extensions@2021-04-01' = {
  parent: vmss
  name: 'JoinHostPool'
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.77'
    autoUpgradeMinorVersion: true
    settings: {
      modulesUrl: '${artifactsLocation}Configuration.zip'
      configurationFunction: 'Configuration.ps1\\AddSessionHost'
      properties: {
        HostPoolName: hostPoolName
        registrationInfoToken: hpReload.properties.registrationInfo.token
      }
    }
  }
}
