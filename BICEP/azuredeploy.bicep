/*
Purpose:
To deploy and configure the storage and automation account in the CORE Subscriptions for the purposes of scaling the AVD solution.
the storage account will contain three storage tables:
 - Schedules  - this provides a list of schedules to use that are desktop agnostic
 - Desktops - this links the desktops to the schdules to be used
 - Bankholidays - a list of bank holidays generated and stored by querying the Gov.uk api

 The Automation Account will be set up using a machine identity that will have permission to read the schedules and desktops tables.  when a new desktop
 is deployed, it will also deploy a runbook

 When building, there will be a CORE-DEV table+AA that will schedule for (at time of writing) DEV, TEST and UAT.  And a CORE-PROD table+aa that will schedule
 only for prod.  this system will mean when the AVD is rebuilt around CORE-DEV/PROD, the amount of scaler rework is minimal.
*/

/*
PRE-REQS
- The AVD service must already be deployed
- The CORE networks and subnets must already be deployed
- The CORE LAW must be deployed
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

@description('Deployment subscription ID')
param subID string = subscription().subscriptionId

@description('Log analytics RG')
//!!!CONFIG!!!
param lawRG string = toUpper('EHP-RG-POC-${localenv}')

@description('Log analytics Name')
//!!!CONFIG!!!
param lawName string = toLower('ehppoc-law-${localenv}')

@description('Log analytics SubID')
param lawSubID string = subID

var tags = {
  Environment: toUpper(localenv)
}

//VARIABLES
//!!!CONFIG!!!
var ehpScalerConfig = {
    storageName: toLower('ehpstscaler${localenv}')
    storageRG: toUpper('EHP-RG-SCALER-${localenv}')
    storageSubID: subID
    storageTableScheduleName: 'ScalerSchedules'
    storageTableDesktopName: 'ScalerDesktops'
    storageTableBankholidayName: 'ScalerBankHolidays'
    aaName: toLower('ehp-aa-ehpscaler-${localenv}')
}

//Pull in LAW
resource diagLog 'Microsoft.OperationalInsights/workspaces@2021-06-01' existing = {
  name: lawName
  scope: resourceGroup(lawSubID,lawRG)
}

//Build the Storage Account and configure the tables
//Note: Due to changes in azure which prevent you from "edit or replace" previous deployment, DNS and PEP are an optional update
module ScalerStorage './modules/StorageAccount.bicep' = {
  name: 'ScalerStorage'
  params: {
    location: location
    tags: tags
    lawID: diagLog.id
    storageAccountName: ehpScalerConfig.storageName
    allowSharedKeyAccess: true
    allowPublicNetworkAccess: 'Enabled'

    tables: [
      {
        name: ehpScalerConfig.storageTableScheduleName
      }
      {
        name: ehpScalerConfig.storageTableDesktopName
      }
      {
        name: ehpScalerConfig.storageTableBankholidayName
      }
    ]
  }
}

//Build the Automation Account
//Note: Due to changes in azure which prevent you from "edit or replace" previous deployment, DNS and PEP are an optional update
//Note:Localauth has to be enabled for the logic app to be able to use the webhook
module ScalerAA './modules/AutomationAccount.bicep' = {
  name: 'ScalerAA'
  params: {
    location: location
    tags: tags
    lawID: diagLog.id
    aaName: ehpScalerConfig.aaName
    enablePublicNetworkAccess: true
    disableLocalAuth: true
  }
}
