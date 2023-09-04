//Create a table in a storage account
//Must be correctly scoped to the RG where the storage account exists

//Todo: Add the table and give it the correct permissions and set up access policies

@description('Name of the storage account to add a share to')
param storageAccountName string

@description('Optional: The default path to add a table to.  Defaults to "/default"')
param storageTablePath string = '/default'

@description('The name of the share to create')
param tableName string

var lowerTableName = toLower(tableName)

//RESOURCE
resource StorageAccShare 'Microsoft.Storage/storageAccounts/tableServices/tables@2022-05-01' = {
  name: '${storageAccountName}${storageTablePath}/${lowerTableName}'
  properties: {}
}
