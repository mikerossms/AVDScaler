//Create a container in a storage account
//Must be correctly scoped to the RG where the storage account exists

//Todo: Add the container and give it the correct permissions

param storageAccountName string
param storageContainerPath string = '/default'
param containerName string 
//param permissions object

//Permissions object:
// {
//   ???
// }

//MODULES
resource StorageAccContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-04-01' = {
  name: '${storageAccountName}${storageContainerPath}/${containerName}'
  properties: {
    publicAccess: 'None'
  }
}
