//TODO:
//Take a parameter for storage account containers and file shares and set them up with the correct permissions - calls storage-container.bicep and storage-fileshare.bicep
//The attribute 'isHnsEnabled' needs to be optional on [bool] newDeployment = true

@description('Required - Tags for the deployed resources')
param tags object

@description('Optional - Geographic Location of the Resources.  Default: same as resource group')
param location string = resourceGroup().location

@description('Optional - ID of the Log Analytics service to send debug info to.  Default: none')
param lawID string = ''

@description('Required - Name of the storage account')
param storageAccountName string

@description('Optional - TLS version.  Default: TLS1_2')
param tlsVersion string = 'TLS1_2'

@description('Optional - Determines whether blob access is public.  Default: false')
param allowPublicBlobAccess bool = false

@description('Optional - Determines whether there is public access to the storage account.  Default: false')
@allowed([
  'Disabled'
  'Enabled'
])
param allowPublicNetworkAccess string = 'Disabled'

@description('Optional - Determines whether the storage account permits access to the shared keys.  Default: false')
param allowSharedKeyAccess bool = false

@description('Optional - Storage tier to use.  Default: hot')
@allowed([
  'Hot'
  'Cool'
])
param accessTier string = 'Hot'

@description('Optional - Storage SKU to use.  Default: Standrad_LRS')
param sku string = 'Standard_LRS'

@description('Optional - Enable Hierarichal Data Storage.  Default: false')
param hnsEnabled bool = false

@description('Optional - Days to retain files after delete (soft delete).  Zero turns off soft delete.  Default: 0')
param softDeleteDays int = 0

// @description('Network config for Private endpoint (Common Config->vnet->localenv)')
// param vnetConfig object = {}

@description('Array of vnet/snet ids to allow through the firewall')
param virtualNetworkRules array = []
//[{id: vnet/snet}...]

// @description('Subnet to deploy endpoint')
// param endpointSnetName string = ''

// @description('Optional/Required - DNS config for the local environment where an endpoint is to be added - required where Endpoints are deployed.  Default: {}')
// param dnsConfig object = {}

// @description('Optional - Determines whether a Blob endpoint and DNS entry is created')
// param createBlobEndpoint bool = false

// @description('Optional - Determines whether a File endpoint and DNS entry is created')
// param createFileEndpoint bool = false

// @description('Optional - Determines whether a DFS private endpoint is created')
// param createDFSEndpoint bool = false

// @description('Optional - Determines whether a Table private endpoint is created')
// param createTableEndpoint bool = false

@description('Optional - Determine whether this account can be replicated across tenant.  Default: false')
param allowCrossTenantReplication bool = false

@description('Optional - Determine whether to set AAD as the default authentication.  Default: true')
param defaultToADDAuthentication bool = true

// @description('Optional - Deploy the DNS record.  Default: true')
// param deployDNSRecord bool = true

@description('Options - List of Blob Containers to create.')
param blobContainers array = []
//format is:
//[
//  {
//    name: 'containername'
//    permissions: []
//  }
//]

@description('Optional - List of SMB Shares to create')
param fileShares array = []
//format is:
//[
//  {
//    name: 'filesharename'
//  }
//]

@description('Optional - List of tables to create')
param tables array = []

@description('Optional - Specify the storage account kind.  Default: StorageV2')
@allowed([
  'BlobStorage'
  'BlockBlobStorage'
  'FileStorage'
  'Storage'
  'StorageV2'
])
param storageAccountKind string = 'StorageV2'

// @description('Options - List of File Shares to create')
// param fileShares array = []

@description('Optional - Provide object containing AAD based auth for files')
param azureFilesIdentityBasedAuthentication object = {}
// {
//   directoryServiceOptions: 'AADDS'
//   activeDirectoryProperties: {
//     domainName: 'mydomain.co.uk'
//   }
//   defaultSharePermission: 'None'
// }

// e.g. {
//   directoryServiceOptions: 'AADDS'
//   activeDirectoryProperties: {
//     domainName: 'mydomain.co.uk'
//   }
//   defaultSharePermission: 'None'
// }


//VARIABLES

//RESOURCES
resource StorageAcc 'Microsoft.Storage/storageAccounts@2022-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: storageAccountKind
  sku: {
    name: sku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowBlobPublicAccess: allowPublicBlobAccess
    minimumTlsVersion: tlsVersion
    isHnsEnabled: hnsEnabled
    allowSharedKeyAccess: allowSharedKeyAccess
    allowCrossTenantReplication: allowCrossTenantReplication
    defaultToOAuthAuthentication: defaultToADDAuthentication
    publicNetworkAccess: allowPublicNetworkAccess
    azureFilesIdentityBasedAuthentication: empty(azureFilesIdentityBasedAuthentication) ? json('null') : azureFilesIdentityBasedAuthentication
    
    networkAcls: allowPublicNetworkAccess == 'Enabled' ? {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
      virtualNetworkRules: []
    } : {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: virtualNetworkRules
    }
    
    supportsHttpsTrafficOnly: true
    accessTier: storageAccountKind == 'Storage' ? null : accessTier
  }
}

//Configure default containers
resource Container 'Microsoft.Storage/storageAccounts/blobServices@2022-05-01' = {
  name: 'default'
  parent: StorageAcc
  properties: {
    containerDeleteRetentionPolicy: {
      enabled: softDeleteDays > 0 ? true : false
      days: softDeleteDays > 0 ? softDeleteDays : json('null')
    }
    deleteRetentionPolicy: {
      enabled: softDeleteDays > 0 ? true : false
      days: softDeleteDays > 0 ? softDeleteDays : json('null')
    }
  }
}

//Configure default files
resource File 'Microsoft.Storage/storageAccounts/fileServices@2022-05-01' = {
  name: 'default'
  parent: StorageAcc
  properties: {
    protocolSettings:{
      smb:{
        authenticationMethods: 'Kerberos'
        channelEncryption: 'AES-256-GCM;AES-128-GCM'
        kerberosTicketEncryption: 'AES-256;RC4-HMAC'
        versions: 'SMB3.1.1'
      }
    }
    shareDeleteRetentionPolicy: {
      enabled: softDeleteDays > 0 ? true : false
      days: softDeleteDays > 0 ? softDeleteDays : json('null')   
    }
  }
}

//Configure default Tables
resource Table 'Microsoft.Storage/storageAccounts/tableServices@2022-05-01' = {
  name: 'default'
  parent: StorageAcc
  properties: {}
}

// //Configure a private endpoint for blob
// module PrivateEndpointBlob 'privateEndpoint.bicep' = if (createBlobEndpoint) {
//   name: 'privateEndpointBlob'
//   params: {
//     tags: tags
//     location: location
//     privateEndpointName: '${toLower(StorageAcc.name)}-blob-pep-${vnetConfig.vnetName}-${endpointSnetName}'
//     dnsName: deployDNSRecord ? StorageAcc.name : ''
//     dnsConfig: dnsConfig
//     vnetConfig: vnetConfig
//     endpointSnetName: endpointSnetName
//     serviceType: 'blob'
//     serviceID: StorageAcc.id
//   }
//   dependsOn: [
//     Container
//   ]
// }

// //Configure a private endpoint for file Share
// module PrivateEndpointFile 'privateEndpoint.bicep' = if (createFileEndpoint) {
//   name: 'privateEndpointFile'
//   params: {
//     tags: tags
//     location: location
//     privateEndpointName: '${toLower(StorageAcc.name)}-file-pep-${vnetConfig.vnetName}-${endpointSnetName}'
//     dnsName: deployDNSRecord ? StorageAcc.name : ''
//     dnsConfig: dnsConfig
//     vnetConfig: vnetConfig
//     endpointSnetName: endpointSnetName
//     serviceType: 'file'
//     serviceID: StorageAcc.id
//   }
//   dependsOn: [
//     File
//     PrivateEndpointBlob
//   ]
// }

// //Configure a private endpoint for file DFS
// module PrivateEndpointDFS 'privateEndpoint.bicep' = if (createDFSEndpoint) {
//   name: 'privateEndpointDFS'
//   params: {
//     tags: tags
//     location: location
//     privateEndpointName: '${toLower(StorageAcc.name)}-dfs-pep-${vnetConfig.vnetName}-${endpointSnetName}'
//     dnsName: deployDNSRecord ? StorageAcc.name : ''
//     dnsConfig: dnsConfig
//     vnetConfig: vnetConfig
//     endpointSnetName: endpointSnetName
//     serviceType: 'dfs'
//     serviceID: StorageAcc.id
//   }
//   dependsOn: [
//     PrivateEndpointFile
//   ]
// }

// //Configure a private endpoint for Table
// module PrivateEndpointTable 'privateEndpoint.bicep' = if (createTableEndpoint) {
//   name: 'PrivateEndpointTable'
//   params: {
//     tags: tags
//     location: location
//     privateEndpointName: '${toLower(StorageAcc.name)}-table-pep-${vnetConfig.vnetName}-${endpointSnetName}'
//     dnsName: deployDNSRecord ? StorageAcc.name : ''
//     dnsConfig: dnsConfig
//     vnetConfig: vnetConfig
//     endpointSnetName: endpointSnetName
//     serviceType: 'table'
//     serviceID: StorageAcc.id
//   }
//   dependsOn: [
//     PrivateEndpointFile
//   ]
// }

//Add to log analytics if provided ID
resource StorageAccLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(lawID)) {
  scope: StorageAcc
  name: StorageAcc.name
  properties: {
    workspaceId: lawID
    metrics: [
      {
        category: 'Capacity'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
    ]
    logs: []
  }
}

resource BlobLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(lawID)) {
  scope: Container
  name: '${StorageAcc.name}-Blobs'
  properties: {
    workspaceId: lawID
    logs: [
      {
        category: 'StorageRead'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
      {
        category: 'StorageWrite'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
      {
        category: 'StorageDelete'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
    ]
  }
  dependsOn: [
    StorageAccLogs
  ]
}

resource FileLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(lawID)) {
  scope: File
  name: '${StorageAcc.name}-Files'
  properties: {
    workspaceId: lawID
    logs: [
      {
        category: 'StorageRead'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
      {
        category: 'StorageWrite'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
      {
        category: 'StorageDelete'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
    ]
  }
  dependsOn: [
    BlobLogs
  ]
}

resource TableLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(lawID)) {
  scope: Table
  name: '${StorageAcc.name}-Tables'
  properties: {
    workspaceId: lawID
    logs: [
      {
        category: 'StorageRead'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
      {
        category: 'StorageWrite'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
      {
        category: 'StorageDelete'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
        retentionPolicy: {
          days: 7
          enabled: true
        }
      }
    ]
  }
  dependsOn: [
    FileLogs
  ]
}

//Add the Containers
@batchSize(1)
module AddContainers 'StorageAccount-Container.bicep' = [ for (ctnr,i) in blobContainers: {
  name: 'addContainer${i}'
  params: {
    storageAccountName: StorageAcc.name
    storageContainerPath: '/default'
    containerName: toLower(ctnr.name)
  }
  dependsOn: [
    Container
  ]
}]

//Add the files
module AddFileShares 'StorageAccount-Share.bicep' = [ for (share,i) in fileShares: {
  name: 'addFileShare${i}'
  params: {
    storageAccountName: StorageAcc.name
    shareName: toLower(share.name)
    storageSharePath: '/default'
    tier: 'Hot'
  }
}]

//Add the tables
module AddTables 'StorageAccount-Table.bicep' = [ for (table,i) in tables: {
  name: 'addtable${i}'
  params: {
    storageAccountName: StorageAcc.name
    tableName: toLower(table.name)
    storageTablePath: '/default'
  }
}]

output StorageAccID string = StorageAcc.id
output StorageAccName string = StorageAcc.name
output defaultContainerID string = Container.id
output defaultFileShareID string = File.id
