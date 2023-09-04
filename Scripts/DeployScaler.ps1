<#
.SYNOPSIS
This script sets up the required components for the VMSS based Ephemeral Host Pool scaler and provides a set of default schedules to populate the schedules table
If the table data already exists, no changes to existing schedules will be made

Graph is required: Install-Module Microsoft.Graph -Scope CurrentUser

WHEN to deploy this script:
 - When ANY new desktop has been added or removed
 - When ANY changes have been made to the BICEP
 - When ANY resource has changed and may need replacement RBAC controls
 - If you want to re-create the schedule and desktop tables
 - When you want to update the bank holiday table

Example: update the live runbooks to reflect code changes in your repo
.\Scripts\DeployScaler.ps1 -env prod -dryrun $false -updateRunbook $true -updateBankHoliday $false

Example: only recreate the schedules
.\Scripts\DeployScaler.ps1 -env prod -dryrun $false -updateBankHoliday $false -updateSchedules $true

.PREREQS
 - one (ideally two) subscriptions
 - a deployed Host Pool powered by underlying VMSS configured for ephemeral disks
 - Log Analytics workspace to connect deployed resources to

.DESCRIPTION
Sets up the following (via bicep):
- Storage account : <subscription>/EHP-RG-SCALER-<ENV>/ehpstscaler<ENV>
    - Table: ScalerSchedules
    - Table: ScalerDesktops
    - Table: ScalerBankHolidays

- Automation Account: <subscription>/EHP-RG-SCALER-<ENV>/ehp-aa-ehpscaler-<ENV>

Once Bicep has run, the script will then do the following:
- Populate the ScalerSchedules with a default schedule list, but only if no existing schedules exist
- Update the bank holidays table
- Set up a User Assigned Managed Identity : ehp-umi-scaler-<ENV>
- Assign that identity to the Automation Account
- Set up runbooks for each of the "ScalerDesktops"
- Configure the Automation account task schedule

While the script does take an "ENV" variable for testing purposes in the DEV environment, it is expected that
all the schedules will generally operate from PROD

Script takes the following parameters:
 -env       [dev | prod]        Where to deploy the SCALER resources - default: prod
 -azLogin   [$true | $false]    Determines whether the script will do an interactive login - default: $true
 -dryRun    [$true | $false]    Determines whether to run live or in a what-if scenario - default: $true
 -deployBicep [$true  $false]   Whether to deploy the bicep file or not - default: $true
 -forceTableUpdate [$true | $false] For the update of the schedule and desktop tables overriting any changes with the defaults
 -updateBankHoliday [$true | $false] whether to run the bank holiday table update from the gov.uk site - default to $true
 -assignRoles [$true | $false] Whether to update the RBAC roles on VMSS and Desktop objects - this is important when a new desktop is added
 -updateRunBook [$true | $false] whether to update the content of the Automation Account Runbook AND its schedules
 -updateSchedules [$true | $false] whether to update just the schedules of the Automation Account Runbook
 -schedulesEnabled [$true | $false] Whether the schedules are set to Enabled (true) or disabled (false)
 -newBuild [$true | $false] Shortcut to enable everything required for a new build instead of specifying each individually

.NOTES
While you can deploy this to a DEV environment for testing purposes, be aware that this application can and will run against
all the schedules, desktops and environments that the storage tables have defined.  This can include PROD resources. 
BE CAREFUL WITH THIS otherwise you will end up with a clash.  To avoid issues make sure that in the Desktops table, that
the RunEnvironment colum is properly filled in to allocate desktops to the correct run environment i.e. coredev or coreprod.

PUBLIC NETWORK ACCESS must be enabled on the storage account (so be careful with RBAC) otherwise the AA account cannot see it.
the only way to work around this is to use a Hybrid runbook worker (known issue)

TODO
Change AZURE CLI to AZURE POWERSHELL to eliminate required second login.

Modules
- Requires AZTable
#>

param (
    [Parameter(Mandatory)]
    [string]$env,    
    [bool]$doLogin = $true,
    [bool]$dryRun = $true,
    [bool]$deployBicep = $false,
    [bool]$forceTableUpdate = $false,
    [bool]$updateBankHoliday = $true,
    [bool]$assignRoles = $false,
    [bool]$updateRunBook = $false,
    [bool]$updateSchedules = $false,
    [bool]$schedulesEnabled = $false,
    [bool]$newBuild = $false
)

# Abort if required module not installed
if ((Get-Module -name Microsoft.Graph.Authentication) -eq $null) {
    Write-Host "Graph is required: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber"
    Write-Host "                   Import-Module Microsoft.Graph -Scope Local -Force"
    Exit 0
}

#Shortcut to rebuild everything
if ($newBuild) {
    $deployBicep = $true
    $forceTableUpdate = $true
    $updateBankHoliday = $true
    $assignRoles = $true
    $updateRunBook = $true
}

##START CONFIG##

#configure the subscriptions
#Please change to suit your environment - a single sub can also be used
#!!!CONFIG!!!
$environments = @{
    "dev" = @{
        "subName" = "<change me>"
        "subID" = "<change me>"
        "scheduleInterval" = 10     #Minutes between schedules
        "runEnvironment" = "ehpdev"
        "aadScalerGroup" = "EHP - Scaler - DEV"
    }
    "prod" = @{
        "subName" = "<change me>"
        "subID" = "<change me>"
        "scheduleInterval" = 10 #Minutes between schedules
        "runEnvironment" = "ehpprod"
        "aadScalerGroup" = "EHP - Scaler - PROD"
    }
}

#the path to the default scaler CSV files for populating the desktop and scheduler tables
$defaultTableDataPath = "..\DefaultScalerConfig"

#storage account configuration
$storageAccountNoEnv = @{
    "storageName" = "ehpstscaler"       #!!!CONFIG!!!
    "storageTableSched" = "ScalerSchedules"
    "storageTableDesk" = "ScalerDesktops"
    "storageTableBH" = "ScalerBankHolidays"
    "csvDefaultTableSched" = "$defaultTableDataPath\defaultSchedules.csv"
    "csvDefaultTableDesk" = "$defaultTableDataPath\defaultDesktops.csv"
}

#Runbooks
$runbooks = @(
    @{
        name = "EHPAutoScaler"
        script = "$PSScriptRoot\EHPDoScaling.ps1"
        type = "PowerShell"
    }
    @{
        name = "EHPScalerParallelRun"
        script = "$PSScriptRoot\EHPScalerParallelRun.ps1"
        type = "PowerShellWorkflow"
    }
    @{
        name = "EHPScalerScheduler"
        script = "$PSScriptRoot\EHPScalerScheduler.ps1"
        type = "PowerShell"
    }
)

$schedulerRunbook = "EHPScalerScheduler"


#Basic defaults for the scaler
#!!!CONFIG!!!
$RGTags = @("Criticality=Tier 1", "Environment=$env".ToUpper(), "Product=EHP Scaler")
$RG = "EHP-RG-SCALER-$env".ToUpper()


$bicepTemplate = "../BICEP/azuredeploy.bicep"

#Names of the AA accounts
$aaAccount = "ehp-aa-ehpscaler-$env"

##END CONFIG##

#Log in
if ($doLogin) {
    az login
}

#Connect to Graph as well
Connect-Graph -scopes "Group.ReadWrite.All"

#Change context
$subid = $environments.$env.subID
$subname = $environments.$env.subName
Write-Host "Changing subscription to: $subname ($subid)" -ForegroundColor Green
az account set --subscription $subid
if ((az account show --query id -o tsv) -ne $subid) {
    Write-Host "ERROR: Cannot change to subscription: $subname ($subid)" -ForegroundColor Red
    exit 1
}

#Create the Resource Group if not exist
if ($deployBicep) {
    if (az group show --name $RG) {
        Write-Host "Resource Group Exists, not changing: $RG" -ForegroundColor Green
    } else {
        Write-Host "Creating Resource Group: $RG" -ForegroundColor Green
        az group create --location "UK South" --resource-group $RG --tags $RGTags
    }

    if (-not (az group show --name  $RG)) {
        Write-Host "ERROR: Resource Group missing: $RG" -ForegroundColor Red
        exit 1
    } else {
        Write-Host "Group Created: $RG" -ForegroundColor Green
    }
}

$saName = "$($storageAccountNoEnv.storageName)$env".ToLower()
$scheduleTableExists = $false
$desktopTableExists = $false

Write-Host "Checking existance of the Storage Account tables in $saName" -ForegroundColor Green
#check if the storage account tables exists.  If they dont, then once the bicep has run to create them
#update them with some defaults, otherwise skip that step later (dont want to overright custom changes)

#Check that the storage account actually exists

if (az storage account show --resource-group $RG --name $saName) {
    Write-Host " - Found Storage Account: $saName"

    Write-Host " - Getting Tables (user auth mode)"
    $tables = (az storage table list --auth-mode login --account-name $saName | ConvertFrom-Json)

    if (-Not $tables) {
        Write-Log "Unable to get the list of storage tables.  Check permissions.  Cannot continue" -ForegroundColor Red
        exit 1
    }

    foreach ($table in $tables) {
        Write-host "    - Found: $($table.name)"
        if (($table.name).ToLower() -eq ($storageAccountNoEnv.storageTableSched).ToLower()) {
            $scheduleTableExists = $true
        }
        if (($table.name).ToLower() -eq ($storageAccountNoEnv.storageTableDesk).ToLower()) {
            $desktopTableExists = $true
        }
    }
}

#If the "forceTableUpdate" bool is set then forcefully update the table with the defauly schedule overriding anything that was there.
if ($forceTableUpdate) {
    $scheduleTableExists = $false
    $desktopTableExists = $false
}

#Run the BICEP script (resource group level script)
if ($deployBicep) {
    Write-Host ""
    Write-Host "Deploying the Bicep File: $bicepTemplate" -ForegroundColor Green
    #For a what-if by default (information only)
    if ($dryRun) {
        Write-Host "DRY RUN (no resource changes)" -ForegroundColor Magenta
        az deployment group create --resource-group $RG --name "EHPScaler" --template-file $bicepTemplate --parameters localenv=$env --verbose --what-if
    
    } else {
        #Do a  live change (resource update)
        Write-Host "LIVE RUN (with resource changes if required)" -ForegroundColor Magenta

        #force all existing deployments to the resource group to stop
        Write-Host "Checking to see if there are any previous running deployments (will cancel them)" -ForegroundColor Green

        foreach ($depObj in (az deployment group list --resource-group $RG | ConvertFrom-Json)) {
            if (($depObj.properties.provisioningState).ToLower() -eq 'running') {
                Write-Host " - Cancelling previous deployment: $($depObj.name)"
                az deployment group cancel --resource-group $RG --name $depObj.name
            }
        }
        #Deploy the resources
        Write-Host "Running Build" -ForegroundColor Green
        $result = az deployment group create --resource-group $RG --name "EHPScaler" --template-file $bicepTemplate --parameters localenv=$env --verbose | ConvertFrom-Json
        if ($result.properties.provisioningState -ne "Succeeded") {
            Write-Host "Bicep deployment failed - cannot continue" -ForegroundColor Red
            Write-Host "Has the BICEP pre-req been met? - CORE network, subnet and NSG deployment is required"
            exit 1
        }
    }

    Write-Host "Deploying the Bicep File Complete" -ForegroundColor Green
    Write-Host ""
} else {
    Write-Host "Skipping Bicep Deployment" -ForegroundColor Yellow
}


#Assign Roles Part 1 - Resolve access to the Storage Accounts so content can be added to the tables
if ($assignRoles) {
    #Create a AAD group for the Scaler (if not exist)
    $aadGroup = $environments.$env.aadScalerGroup

    Write-Host "Creating AAD group: $aadGroup"
    $groupObjectID = ""
    $checkGroupExists = Get-MgGroup -Filter "DisplayName eq '$aadGroup'"
    if ($checkGroupExists.count -gt 0 ) {
        $groupObjectID = $checkGroupExists.id
        Write-Host "Group already exists ID: $groupObjectID"
    } else {
        $groupObject = New-MgGroup -DisplayName $aadGroup -MailEnabled:$False -MailNickName 'NotSet' -SecurityEnabled
        $groupObjectID = $groupObject.id
        Write-Host "Created new Group ID: $groupObjectID"
    }

    if (-Not $groupObjectID) {
        Write-Host "ERROR: Group has not been created in AAD - Permissions?" -ForegroundColor Red
        exit 1
    }

    #Add the AA managed ID to the group
    Write-Host "Add Automation Account Managed ID to the AAD Group" -ForegroundColor Green

    #Get the System assigned managed id of the AA account
    $aaManID = (az automation account show --name $aaAccount --resource-group $RG | ConvertFrom-JSON).identity.principalId
    
    #Add the ID to the AAD Group
    New-MgGroupMember -GroupId $groupObjectID -DirectoryObjectId $aaManID -ErrorAction SilentlyContinue

    #Configure the base scope for the other resources
    $baseScope = "/subscriptions/$($environments.$env.SubID)/resourcegroups/$RG/providers"

    #Set up the storage scope to run against
    $storageScope = "$baseScope/Microsoft.Storage/storageAccounts/$saName"

    #Assign "Storage Account Key Operator Service Role" to the storage account
    New-AzRoleAssignment -RoleDefinitionName "Storage Account Key Operator Service Role" -Scope $storageScope -ObjectID $groupObjectID -ErrorAction SilentlyContinue
    #Assign"Storage Table Data Reader" RBAC to the scaler table
    New-AzRoleAssignment -RoleDefinitionName "Storage Table Data Reader" -Scope $storageScope -ObjectID $groupObjectID -ErrorAction SilentlyContinue

    #Get the object id of the currently connected user with powershell
    $currentUserId = (Get-AzADUser -SignedIn).Id

    #Assing the current running user as "Storage Table Data Contributor" to the storage account
    New-AzRoleAssignment -RoleDefinitionName "Storage Table Data Reader" -Scope $storageScope -ObjectID $currentUserId -ErrorAction SilentlyContinue
    New-AzRoleAssignment -RoleDefinitionName "Storage Table Data Contributor" -Scope $storageScope -ObjectID $currentUserId -ErrorAction SilentlyContinue

}



#If the schedule table was found (unless overridden), skip this otherwise update the table from the defaults CSV file
if ($scheduleTableExists) {
    Write-Host "Schedules table already exists - not updating default schedules" -ForegroundColor Green
} else {
    Write-Host "Adding Default schedules to Schedules table" -ForegroundColor Green
    Write-Host " - importing default CSV schedule"

    #Import the CSv file
    $schedcsv = Import-CSV -Path $storageAccountNoEnv.csvDefaultTableSched

    #Assuming schedule data was valid and we have data then step through each data row and break it out into its components
    if ($schedcsv) {
        foreach($row in $schedcsv)
        { 
            $properties = $row | Get-Member -MemberType Properties
            $rowdata = @()

            #Go through each of the properties and add those a key=value pairs to an array
            for($i=0; $i -lt $properties.Count;$i++)
            {
                $column = $properties[$i]
                $columnvalue = $row | Select-Object -ExpandProperty $column.Name
                $rowdata += "$($column.Name)='$columnvalue'"
            }
            
            #Assuming we have key=value data in the array, join that on space, then run the AZ Inster to table command
            if ($rowdata.length -gt 0) {
                #$partkey = $row.PartitionKey
                $rowstring = $rowdata -join " "
                Write-Host " - Inserting Schedule: $($row.PartitionKey)"
                $command = "az storage entity insert --account-name $saName --auth-mode login --table-name $($storageAccountNoEnv.storageTableSched) --entity $($rowstring) --if-exists replace"
                if (-Not $dryRun) {
                    Invoke-Expression $command
                } else {
                    Write-Host "DRYRUN: Invoke-Expression $command"
                }
            }
        } 
    } else {
        Write-Host "WARN: Unable to import CSV file: $($storageAccountNoEnv.csvDefaultTableSched)"
    }
}

#If the Desktop assignment table was found (unless overridden), skip this otherwise update the table from the defaults CSV file
if ($desktopTableExists) {
    Write-Host "Desktops table already exists - not updating default desktops" -ForegroundColor Green
} else {
    Write-Host "Adding Default desktops to Desktops table and assigning default schedules" -ForegroundColor Green
    $deskcsv = Import-CSV -Path $storageAccountNoEnv.csvDefaultTableDesk

    #Assuming schedule data was valid and we have data then step through each data row and break it out into its components
    if ($deskcsv) {
        foreach($row in $deskcsv)
        { 
            $properties = $row | Get-Member -MemberType Properties
            $rowdata = @()

            #Go through each of the properties and add those a key=value pairs to an array
            for($i=0; $i -lt $properties.Count;$i++)
            {
                $column = $properties[$i]
                $columnvalue = $row | Select-Object -ExpandProperty $column.Name
                $rowdata += "$($column.Name)='$columnvalue'"
            }
            
            #Assuming we have key=value data in the array, join that on space, then run the AZ Inster to table command
            if ($rowdata.length -gt 0) {
                $rowstring = $rowdata -join " "
                Write-Host " - Inserting Desktop: $($row.PartitionKey) : $($row.desktop)"
                $command = "az storage entity insert --account-name $saName --auth-mode login --table-name $($storageAccountNoEnv.storageTableDesk) --entity $($rowstring) --if-exists replace"
                Invoke-Expression $command
            }
        } 
    } else {
        Write-Host "WARN: Unable to import CSV file: $($storageAccountNoEnv.csvDefaultTableDesk)"
    }
}

#Update the bank holiday table
if ($updateBankHoliday) {
    Write-Host "Updating Bank Holidays" -ForegroundColor Green
    $bankHolidays = (Invoke-RestMethod -Uri "https://www.gov.uk/bank-holidays.json" -Method GET)
    $engData = $bankHolidays.'england-and-wales'.events

    $pattern = '[^a-zA-Z]'
    $currentYear = get-date -Format yyyy

    foreach ($bh in $engData) {
        #Get the year of the bank holiday - gov website starts at 2018 (at time of writing) which we dont need
        $bhYear = (($bh.date).Split("-"))[0]
        
        #If the bank hol year is greater or equal to the current year, then process those entries
        if ($bhYear -ge $currentYear) {
            #Replace the non alphanum chars in the name
            $title = ($bh.title) -Replace $pattern,''
            $rowstring = "PartitionKey='$($title)' RowKey='$($bh.date)'"

            write-Host "Processing: $rowstring"
            $command = "az storage entity insert --account-name $saName --auth-mode login --table-name $($storageAccountNoEnv.storageTableBH) --entity $($rowstring) --if-exists replace"
            Invoke-Expression $command
        }
    }
}

#Assign Roles to resources part 2 - add roles to the associated HP and VMSS
if ($assignRoles) {
    Write-Host "Updating RBAC Roles" -ForegroundColor Green
    #Configre the base scope
    $baseScope = "/subscriptions/$($environments.$env.SubID)/resourcegroups/$RG/providers"

    #Get the desktops data from the table
    $desktopsData = (az storage entity query --account-name $saName --auth-mode login --table-name $storageAccountNoEnv.storageTableDesk | ConvertFrom-Json).items

    #Get the AA Scope
    $aaScope = "$baseScope/Microsoft.Automation/automationAccounts/$aaAccount"
    # $aaManID = (az automation account show --name $aaAccount --resource-group $RG | ConvertFrom-JSON).identity.principalId

    #Get the AAD Group
    $groupObjectID = (Get-MgGroup -Filter "DisplayName eq '$aadGroup'").id
    if (-Not $groupObjectID) {
        Write-Host "ERROR: Cannot re-acquire the AAD group '$aadGroup'" -ForegroundColor Red
        exit 1
    }

    #Assign the AA managed ID to itself with role: Automation Contributor.  this is needed in order for one runbook to access another
    New-AzRoleAssignment -RoleDefinitionName "Automation Contributor" -Scope $aaScope -ObjectID $groupObjectID -ErrorAction SilentlyContinue

    #Step through each VMSS/HP in the RG and assign the RBAC role (get the info from the desktop table)
    foreach ($desktopObject in $desktopsData) {
        if (($desktopObject.RunEnvironment).toLower() -eq $environments.$env.runEnvironment) {
            $vmss = ($desktopObject.VMSSName).ToLower()
            $hp = ($desktopObject.HPName).ToLower()
            $thisScope = "/subscriptions/$($desktopObject.DesktopSubID)/resourceGroups/$($desktopObject.DesktopRG)/providers"

            Write-Host " - Assigning system assigned managed identity roles to - $vmss and $hp"

            $vmssScope = "$thisScope/Microsoft.Compute/virtualMachineScaleSets/$vmss"
            Write-Host " - VMSS Scope: $vmssScope"

            $vmssRole = Get-AzRoleAssignment -Scope $vmssScope -ObjectID $groupObjectID
            if (-not $vmssRole) {
                New-AzRoleAssignment -RoleDefinitionName "Contributor" -Scope $vmssScope -ObjectID $groupObjectID #-ErrorAction SilentlyContinue
            } else {
                if (($vmssRole).RoleDefinitionName.Contains('Contributor') -eq $false) {
                    New-AzRoleAssignment -RoleDefinitionName "Contributor" -Scope $vmssScope -ObjectID $groupObjectID #-ErrorAction SilentlyContinue
                }
            }
            
            #Leaving code in case you need to use it in future
            #$vmssScope = "$thisScope/Microsoft.Compute/virtualMachineScaleSets/$vmss"
            #Remove-AzRoleAssignment -RoleDefinitionName "Desktop Virtualization Virtual Machine Contributor" -Scope $vmssScope -ObjectID $groupObjectID #-ErrorAction SilentlyContinue

            $hostPoolScope = "$thisScope/Microsoft.DesktopVirtualization/hostpools/$hp"
            $hpRole = Get-AzRoleAssignment -Scope $hostPoolScope -ObjectID $groupObjectID
            if ($hpRole) {
                if (($hpRole).RoleDefinitionName.Contains('Contributor') -eq $false) {
                    New-AzRoleAssignment -RoleDefinitionName "Contributor" -Scope $hostPoolScope -ObjectID $groupObjectID #-ErrorAction SilentlyContinue
                }
            } else {
                New-AzRoleAssignment -RoleDefinitionName "Contributor" -Scope $hostPoolScope -ObjectID $groupObjectID #-ErrorAction SilentlyContinue
            }
            #Leaving code in case you need to use it in future
            # $hostPoolScope = "$thisScope/Microsoft.DesktopVirtualization/hostpools/$hp"
            # Remove-AzRoleAssignment -RoleDefinitionName "Desktop Virtualization Host Pool Contributor" -Scope $hostPoolScope -ObjectID $groupObjectID #-ErrorAction SilentlyContinue

            #Assign reader to the RG itself
            $rgScope = "/subscriptions/$($desktopObject.DesktopSubID)/resourcegroups/$($desktopObject.DesktopRG)"
            $rgRole = Get-AzRoleAssignment -Scope $rgScope -ObjectID $groupObjectID
            if ($rgRole) {
                if ((Get-AzRoleAssignment -Scope $rgScope -ObjectID $groupObjectID).RoleDefinitionName.Contains('Reader') -eq $false) {
                    New-AzRoleAssignment -RoleDefinitionName "Reader" -Scope $rgScope -ObjectID $groupObjectID #-ErrorAction SilentlyContinue
                }
            } else {
                New-AzRoleAssignment -RoleDefinitionName "Reader" -Scope $rgScope -ObjectID $groupObjectID #-ErrorAction SilentlyContinue
            }

        }
    }
}

#Creates the runbook and populates it with the EHPDoScaling.ps1 script
if (($updateRunBook) -Or ($updateSchedules)) {
    # Link the schedule to the runbook - annoyingly there is no CLI call and
    # as usual, az rest PUT fails, so forced to log in to Azure with powershell.
    # Probably best to convert the entire script to powershell from CLI
    Write-Host "Need to log into Powershell Azure rather than CLI to apply the schedule" -ForegroundColor Green

    Write-Host "Logging into Azure - User interactive mode"
    $cnx = Connect-AzAccount

    Write-Host "Changing subscription to: $subname ($subid)" -ForegroundColor Green
    $subContext = Set-AzContext -Subscription $subid

    if ($subContext.subscription.id -ne $subid) {
        Write-Host "Cannot change to subscription: $subname ($subid)" -ForegroundColor Red
        exit 1
    }

    #Upload the runbooks
    if ($updateRunBook) {
        foreach ($runbookData in $runbooks) {
            #Create the Runbook from the EHPDoScaling.ps1 script and add a webhook
            #NOTE: could do with some additional checking here hense the capture into variables
            Write-Host "Creating Runbook (if not already created) - $($runbookData.name)" -ForegroundColor Green
            $runbook = az automation runbook create --automation-account-name $aaAccount --resource-group $RG --name $runbookData.name --type $runbookData.type | ConvertFrom-Json
        
            Write-Host "Adding runbook content: '$($runbookData.script)'" -ForegroundColor Green
            $rbScript = $runbookData.script
            $rbContent = az automation runbook replace-content --automation-account-name $aaAccount --resource-group $RG --name $runbookData.name --content @$rbScript
        
            Write-Host "Publish the Runbook - $($runbookData.name)" -ForegroundColor Green
            $rbPublish = az automation runbook publish --automation-account-name $aaAccount --resource-group $RG --name $runbookData.name
        
        }
    }

    #Import the AZTable Module
    New-AzAutomationModule -AutomationAccountName $aaAccount -ResourceGroup $RG -Name "AzTable" -ContentLinkUri "https://www.powershellgallery.com/api/v2/package/AzTable"

    #Deploy the schedules - in order to do this you need to build a recurring schedule
    #As AA schedules lowest granularity is 1 hour, you need to build a series of them starting at a set number of minutes past
    #the hour.  the number of these depends on the interval required.
    $interval = $environments.$env.scheduleInterval
    if (-Not $interval) {
        $interval = 10 #i.e. every 10 mins, so 6 schedules
    }

    $numSchedules = [math]::Floor(60/$interval)
    $dateTimeAtNextHour = (Get-Date -Minute 0 -Second 0).AddHours(1)

    Write-Host "Updating Schedules - $interval minute intervals ($numSchedules schedules to create)" -ForegroundColor Green

    #Delete all existing schedules where the schedule start with EHPScaler
    $schedules = az automation schedule list --automation-account-name $aaAccount --resource-group $RG | ConvertFrom-Json
    if ($schedules.count -gt 0) {
        foreach ($sched in $schedules) {
            if (($sched.name).StartsWith("EHPScaler")) {
                Write-Host " - Deleting Schedule: $($sched.name)"
                az automation schedule delete --automation-account-name $aaAccount --resource-group $RG --name $sched.name --yes
            }
        }
    }

    #Add the new schedules based on interval
    for ($i=0; $i -lt $numSchedules; $i++) {
        $increment = $i * $interval
        $dateTime = (Get-Date -Date $dateTimeAtNextHour).AddMinutes($increment)
        $startTime = "$(Get-Date -Date $dateTime -Format "HH:mm"):00.00000" #Cant start at a "past" DateTime

        Write-Host " - Adding Schdule EHPScaler$i with Start $startTime"
        $schedule = az automation schedule create --automation-account-name $aaAccount --resource-group $RG --interval 1 --frequency "hour" --start-time $startTime --name "EHPScaler$i" | ConvertFrom-Json
        if (-Not $schedule.isEnabled) {
            Write-Host "Failed to add schedule: EHPScaler$i"
        }

        #confgigure the schdule to be enabled or disabled depending on parameter $schedulesEnabled
        $schedStatus = az automation schedule update --automation-account-name $aaAccount --resource-group $RG --name "EHPScaler$i" --is-enabled $schedulesEnabled | ConvertFrom-JSON
        if (-Not $schedStatus.isEnabled) {
            Write-Host "Failed to set schedule enabled/disabled status: EHPScaler$i"
        }

        #Link the schedule to the runbook
        Write-Host "Applying schedule to the EHP Scaler Scheduler runbook - $schedulerRunbook" -ForegroundColor Green
        $params = @{
            runEnvironment = $environments.$env.runEnvironment
        }
        $result = Register-AzAutomationScheduledRunbook -RunbookName $schedulerRunbook -ScheduleName $schedule.name -Parameters $params -ResourceGroupName $RG -AutomationAccountName $aaAccount
        if (-Not $result) {
            Write-Host "Failed to link Runbook and schdule" -ForegroundColor Yellow
        }
    }
}

Write-Host "Finished" -ForegroundColor Green