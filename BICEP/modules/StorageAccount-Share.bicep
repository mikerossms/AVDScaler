//Create a container in a storage account
//Must be correctly scoped to the RG where the storage account exists

//Todo: Add the container and give it the correct permissions

@description('Name of the storage account to add a share to')
param storageAccountName string

@description('Optional: The default path to add a share to.  Defaults to "/default"')
param storageSharePath string = '/default'

@description('The name of the share to create')
param shareName string

@description('The access tier for the share - can be Hot, Cool, Premium and TransactionOptimized.  Default: Hot')
@allowed([
  'Hot'
  'Cool'
  'Premium'
  'TransactionOptimized'
])
param tier string = 'Hot'

var lowerShareName = toLower(shareName)

//RESOURCE
resource StorageAccShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2021-09-01' = {
  name: '${storageAccountName}${storageSharePath}/${lowerShareName}'
  properties: {
    accessTier: tier
    enabledProtocols: 'SMB'
  }
}
