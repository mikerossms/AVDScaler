<#
.SYNOPSIS
    Provides a scheduling function that can handle any number of desktops/schedules based on data stored in a storage table
.DESCRIPTION
    The script takes the list of desktops which have associated schedules attached and works out the currently active schedule
    based on two things - the order that the schedules are listed, and whether the schedule is valid at that moment in time
    the first active schdule will always be used.

    The script supports a number of "generic" schedules as well:
    - manual : Effectivly turns off the auto-scaling and lets the user take control
    - off : Scales the VMSS and HostPool to zero
    - bankholiday : A special case that reads the contents of a "bankholiday" table that is populated using the deployment script with
                    data coming via API from the UK government (so should always be right).  this treats the desktop as though it was a weekend
    
    It also understands the concept of working days, weekends and individual days for schedules ensuring that only the correct number of
    desktops are active at any one time.

    It ensures that there is an upper limit on the number of VMS and sessions, avoids runaway scaling by ensuring that the hostpool is no more than 
    "manimuminstancsescaling" behind the VMSS and deletes old/orphened resources

    On scale down it NEVER kicks users off the system unless forced.  If forced (e.g. VMSS scaled to zero), it will clean up any host pool
    and other resources on the next cycle.

    Run it examples:

    1: Basic dry run with interactive login
    ./EHPDoScaling.ps1 -env dev -desktop analyst

    2: Live run without interactive login
    ./EHPDoScaling.ps1 -env dev -desktop analyst -doLogin $false -dryRun $false

    It is also possible to change the timezone in which this service runs, though this should be left as GMT.
    this script takes BST into account so there is no requirement to manage the times during BST.

    NOTE: The default scaler schedules are only used on deployment and only deployed if there are no existing tables or are forced.

    For further information please see the README.MD
#>

#NOTES:
# - This is written with Powershell modules not CLI.  the reason is that CLI for session hosts is non existent and api calls to
#   manipulate the sessions hosts apepars to be broken (at time of writing - 18/10/22)
# - 


#NOTE:  $env referes to the AVD environment, not the environment of the scaler typically dev,test,uat,prod - required parameter
#       $scalerenv is specific to the SCALER environment being used to run the scaler typically ehpdev or ehpprod - defaults to ehpprod

param (
    [string]$env="",
    [string]$scalerEnv="ehpprod",
    [string]$desktop="",
    [bool]$doLogin = $false,
    [bool]$dryRun = $false,
    [bool]$runAsRunbook = $false
)

#Modules
# Requires AZTable

#Global config
$global:debug = $false           #[true|false] - additional debug information
$global:scaleTestMode = $false   #[true|false] - reduces some of the health checks e.g. "unavailable" hosts, to allow testing without a DC
                                #DO NOT leave this as true for production!
$global:dryRun = $dryRun
$global:timeZone = "GMT Standard Time" #Required for accurate calculations - see: Get-TimeZone -ListAvailable.  azure works in UTC, use the ID of zone

#!!!CONFIG!!!
$global:tenantID = "<change me>"

#Disable autosave of the context for the current powershell script
Disable-AzContextAutosave -Scope Process

<#
.SYNOPSIS
Controlling function that manages the scaling

.DESCRIPTION
checks to see if the service needs to log in (usually only for a manual run), gets the configuration and 
storage table data.  Works out which schedule applies to the desktop (or default if not specified), works
out the desired state, then finally actions the currentstate to achieve the desired state.
#>
function Start-Main {
    param (
        [string]$env,
        [string]$scalerEnv,
        [string]$desktop,
        [bool]$doLogin
    )

    if ($dryRun) {
        Write-Log "DRYRUN - No scaling operations will be carried out" -logType warn
    }

    #Make sure we have an environment and desktop (they are mandatory)
    if (-Not $env) {
        Write-Log "No AVD environment has been specified - mandatory" -logType error
        exit 1
    }

    if (-Not $desktop) {
        Write-Log "No desktop has been specified - mandatory" -logType error
        exit 1
    }

    if (-Not $scalerEnv) {
        Write-Log "No Scaler Environment has been specified - mandatory" -logType error
        exit 1
    }

    #DO NOT CHANGE the Write-Log statement below.  It is required for job testing
    Write-Log "Starting Run::$env::$desktop::$scalerEnv" -LogType good
    ###

    #Log in
    if ($doLogin) {
        Write-Log "Logging into Azure - User interactive mode"
        $cnx = Connect-AzAccount -Tenant $tenantID
        if ($cnx.Context.Tenant.Id -ne $tenantID) {
            Write-Log "Cannot log in with USER credentials" -logType error
            exit 1
        }
    } elseif ($runAsRunbook) {
        Write-Log "Logging into Azure - As Automation Account Managed system ID"
        $cnx = Connect-AzAccount -Identity
        if ($cnx.Context.Tenant.Id -ne $tenantID) {
            Write-Log "Cannot log in with Managed System credentials - my login: $($cnx.Context.Tenant.Id) vs expected login: $tenantID - if inconsistent, check the global tenantID variable" -logType error
            exit 1
        }
    }

    #Get config data for the AVD environment
    $config = Get-Config -env $env -desktopName $desktop.ToLower() -scalerEnv $scalerEnv
    $subscriptions = $config.subscriptions

    if (-Not $subscriptions.Contains($scalerEnv)) {
        Write-Log "The scaler environment provided is invalid - cannot continue" -logType error
        exit 1
    }

    #Change to the SCALER context for the schedule and desktop data
    $subid = $subscriptions.$scalerEnv.subID
    $subname = $subscriptions.$scalerEnv.subName

    Write-Log "Changing subscription to: $subname ($subid)" -logType good
    $subContext = Set-AzContext -Subscription $subid

    if ($subContext.subscription.id -ne $subid) {
        Write-Log "Cannot change to subscription: $subname ($subid)" -logType fatal
        exit 1
    }

    #Get the schedule and desktop data from teh azure table
    Write-Log "Getting Desktop and Scheduler Information from Storage Account" -logType Good
    $tableData = Get-DataFromTable -config $config
    
    $scalerSchedules = $tableData.schedules
    $scalerDesktops = $tableData.desktops
    $scalerBankHols = $tableData.bankholidays

    #Get tthe desktop matching this schedule request
    Write-Log "Searching Desktop information for $desktop"
    $desktopObject = @{}
    foreach ($deskobj in $scalerDesktops) {
        #$deskobj |select-object partitionkey,RowKey,desktop,runenvironment,desktopsubid |format-table
        Write-Log "Environment Check Table: $($deskobj.PartitionKey.ToLower()) vs Actual: $env for $($deskobj.Desktop) using AA $($deskobj.RunEnvironment)" -logtype debug

        if ($deskobj.PartitionKey.ToLower() -eq $env) {
            Write-Log "Environment match found for $($deskobj.Desktop) using AA $($deskobj.RunEnvironment)" -logType debug
            
            if ($deskobj.Desktop.ToLower() -eq $desktop) {
                Write-Log "Desktop match found for $($deskobj.Desktop) in environment $($deskobj.PartitionKey) using AA $($deskobj.RunEnvironment)" -logType good
                Write-Log "Match: Running with parameters: (AA:$($deskobj.RunEnvironment)) / $($deskobj.PartitionKey) / $($deskobj.Desktop) - SubID:$($deskobj.DesktopSubID)  RG:$($deskobj.DesktopRG)" -logType debug
                $desktopObject = $deskobj
            
            } else {
                Write-Log "No match: $desktop and $env running in AA: $($deskobj.RunEnvironment)" -logType debug
            }
        }
    }

    #Checks to make sure the desktop is found otherwise drop out.
    if ($desktopObject.Count -eq 0) {
        Write-Log "Desktop $desktop in Environment $env was not found.  Will not continue" -logType error
        exit 1
    } 

    #Override the config - this was retroadded as the data was made part of the storage table information rather than determined
    $resources = @{
        "subID" = $desktopObject.DesktopSubID
        "RG" = $desktopObject.DesktopRG
        "vmss" = $desktopObject.VMSSName
        "hp" = $desktopObject.HPName
    }

    $config.resources = $resources

    #Get the currently active schedule based on the desktop
    Write-Log "Get the active Schedule for this desktop" -logType Good
    $activeSchedule = Get-ActiveSchedule -desktopObject $desktopObject -config $config -scalerSchedules $scalerSchedules -scalerBH $scalerBankHols
    Write-Output "Got the active schedule: $activeSchedule"

    Write-Log "Active Schedule: $($activeSchedule.PartitionKey)" -logType good
    Write-Log "Schedule Start: $($activeSchedule.TimeStart)"
    Write-Log "Schedule End: $($activeSchedule.TimeEnd)"
    Write-Log "Schedule Recurrance: $($activeSchedule.Recurrance)"
    Write-Log "Schedule Capacity Min: $($activeSchedule.CapacityMin)"
    Write-Log "Schedule Capacity Max: $($activeSchedule.CapacityMax)"
    Write-Log "Schedule Scaling By Maximum: $($activeSchedule.MaxInstanceScaling) instances at a time"

    #Change context to the AVD context so we can action the scaling (the details recorded with the desktop in the "desktop" storage table)
    $subid = $config.resources.subID
    #$subname = $subscriptions.$scalerEnv.subName
    Write-Log "Changing subscription to: $subid" -logType good
    $subContext = Set-AzContext -Subscription $subid

    if ($subContext.subscription.id -ne $subid) {
        Write-Log "Cannot change to subscription: $subid" -logType fatal
        exit 1
    }

    #get the data from the service for VMSS, hosts and users
    Write-Log "Getting the Desktop VMSS and Host Pool Data" -logType good
    $serviceData = Get-ServiceData -config $config -scalerDesktops $scalerDesktops -desktopObject $desktopObject

    #Display the service status in the log
    Write-Log "Display Service Status before Scaling Action" -logType good
    Get-ServiceStatus $desktopObject $activeSchedule $serviceData

    #Do the scale (if required)
    Write-Log "Update the current scale" -logType good
    Update-Scaler $desktopObject $activeSchedule $serviceData
}

<#
.SYNOPSIS
Get the static config data for the service
#>
#!!!CONFIG!!!
function Get-Config {
    param(
        [string]$env,
        [string]$desktopName,
        [string]$scalerEnv
    )

    $subscriptions = @{
        "ehpdev" = @{
            "subName" = "<change me>"
            "subID" = "<change me>"
            "localPostfix" = "dev"
        }
        "ehpprod" = @{
            "subName" = "<change me>"
            "subID" = "<change me>"
            "localPostfix" = "prod"
        }
    }

    if (-Not $subscriptions.Contains($scalerEnv)) {
        Write-Log "The scaler environment provided is invalid - cannot continue" -logType error
        exit 1
    }

    $tables = @{
        "desktops" = @{
            "storageName" = "ehpstscaler$($subscriptions.$scalerEnv.localPostfix)"
            "tableName" = "scalerdesktops"
            "RG" = "EHP-RG-SCALER-$(($subscriptions.$scalerEnv.localPostfix).ToUpper())"
            "subID" = $subscriptions.$scalerEnv.subID
        }
        "schedules" = @{
            "storageName" = "ehpstscaler$($subscriptions.$scalerEnv.localPostfix)"
            "tableName" = "scalerschedules"
            "RG" = "EHP-RG-SCALER-$(($subscriptions.$scalerEnv.localPostfix).ToUpper())"
            "subID" = $subscriptions.$scalerEnv.subID
        }
        "bankholidays" = @{
            "storageName" = "ehpstscaler$($subscriptions.$scalerEnv.localPostfix)"
            "tableName" = "scalerbankholidays"
            "RG" = "EHP-RG-SCALER-$(($subscriptions.$scalerEnv.localPostfix).ToUpper())"
            "subID" = $subscriptions.$scalerEnv.subID
        }
    }

    #this is is here for reasons of legacy - the data is now pulled from the Desktops table.
    $resources = @{
        # "RG" = "XXXX-RG-WVD-$env".ToUpper()
        # "vmss" = "xxxx-vmss-$desktopName-$env".ToLower()
        # "hp" = "xxxx-hp-$desktopName-$env".ToLower()
        "RG" = "-"
        "vmss" = "-"
        "hp" = "-"
        "subID" = "-"
    }

    $configData = @{
        subscriptions = $subscriptions
        tables = $tables
        resources = $resources
    }

    return $configData
}

<#
.SYNOPSIS
Provides a logging function of the script that understands different logging types.  Can easily be extended to disk/table logging

.DESCRIPTION
this function provides a logging system for the AVD scaler.  In the current format it only loggs to the screen.
This would be easily changed if you wanted to log to table or disk

#>
function Write-Log {
    param (
        [string]$logContent = "No info specified",
        [string]$logType = "info",
        [int]$indent = 0,
        [bool]$logToScreen = $true
    )

    $logToAA = $false
    if ($logToScreen) {
        if ($runAsRunbook) {
            $logToScreen = $false
            $logToAA = $true
        }
    }

    $logType = $logType.ToLower()

    #Separate basic info messages
    if (($logType -eq "info") -and ($indent -eq 0)) {
        $indent = 1
    }
    
    if (($logType -eq "info") -and ($indent -eq 0)) {
        $indent = 2
    }

    $indentspace = ""
    $indentSpace = $indentSpace.PadLeft($indent,' ')

    if ($indent -gt 0) {
        $logContent = "$($indentSpace)- $($logContent)"
    }

    if ($logToScreen) {
        Switch ($logType) {
            "info"  { Write-Host $logContent }
            "good"  { Write-Host $logContent -ForegroundColor Green}
            "warn"  { Write-Host "WARN: $logContent" -ForegroundColor Yellow}
            "error" { Write-Host "ERROR: $logContent" -ForegroundColor Red}
            "fatal" { Write-Host "FATAL: $logContent" -ForegroundColor DarkRed}
            "debug" { if ($debug) { Write-Host "DEBUG: $logContent" -ForegroundColor Magenta } }
        }
    }

    if ($logToAA) {
        Switch ($logType) {
            "info"  { Write-Output "INFO: $logContent" }
            "good"  { Write-Output "ACTION: $logContent" }
            "warn"  { Write-Warning "WARN: $logContent" }
            "error" { Write-Error "ERROR: $logContent" }
            "fatal" { Write-Error "FATAL: $logContent" }
            "debug" { if ($debug) { Write-Output "DEBUG: $logContent" } }
        }
    }

}

<#
.SYNOPSIS
This function grabs all the data required for the scaler to operate.

.DESCRIPTION
Gets the data from the Host Pool, VMSS and user information - all required to ensure that scaling only happens
when users are not affected
#>
function Get-ServiceData {
    param (
        [object]$config,
        [object]$scalerDesktops,
        [object]$desktopObject
    )

    $desktopName = $desktopObject.Desktop

    # Set up
    $RG = $config.resources.RG
    $vmss = $config.resources.vmss
    $hp = $config.resources.hp

    #Get the host pool data
    Write-Log "Getting the host pool data: $hp"
    $hostPoolData = Get-HostPoolData -RG $RG -hostPoolName $hp

    #Get VMSS machine list
    Write-Log "Getting the VMSS in VMSS: $vmss"
    $vmssInstanceData = Get-VMSSInstances -RG $RG -vmssName $vmss

    #Get the hosts in host pool:
    Write-Log "Getting list of hosts in pool: $hp"
    $hostsData = Get-HostPoolHosts -RG $RG -hostPoolName $hp -desktopName $desktopName
    Write-Log ""

    #Get the users logged in:
    Write-Log "Getting list of users in pool: $hp"
    $userData = Get-HostPoolUsers -RG $RG -hostPoolName $hp -desktopName $desktopName -hostPoolCount $hostsData.hostCount
    Write-Log ""

    $serviceData = @{
        "vmssData" = $vmssInstanceData
        "hostPoolData" = $hostPoolData
        "hostPoolHostData" = $hostsData
        "userData" = $userData
    }

    return $serviceData
}

<#
.SYNOPSIS
Get the data about the host pool itself

.DESCRIPTION
Takes an RG and host pool name and grabs the the host pool data.
#>
function Get-HostPoolData {
    param (
        [string]$RG,
        [string]$hostPoolName
    )

    Write-Log "Processing Host Pool Data - $RG / $hostPoolName" -logType debug

    #Get the host pool data
    $er = ""
    $hostPoolObject = Get-AzWvdHostPool -ResourceGroupName $RG -Name $hp -ErrorVariable er
    if ($er) {
        Write-Log "Unable to get Host Pool data for $RG / $hp - permissions?" -logType fatal 
        Write-Log "ERROR: $er" 
        exit 1
    }

    Write-Log "Processing Host Pool Data - HostPool Object: $hostPoolObject" -logType debug

    $hostPoolData = @{
        "name" = $hostPoolObject.name
        "friendlyName" = $hostPoolObject.friendlyName
        "description" = $hostPoolObject.description
        "id" = $hostPoolObject.id
        "loadBalancerType" = $hostPoolObject.loadBalancerType
        "maxSessionLimit" = $hostPoolObject.maxSessionLimit
    }

    return $hostPoolData

}

<#
.SYNOPSIS
Get the List of hosts and data about the hosts from the host pool

.DESCRIPTION
Take the RG, host pool name and desktop name and get the list of hosts from the host pool
this includes the state of the hosts themselves 
#>
function Get-HostPoolHosts {
    param (
        [string]$RG,
        [string]$hostPoolName,
        [string]$desktopName
    )

    $hostsData = @{}
    $returnData = @{}

    $hostsBySessionCount = @{}

    Write-Log "Processing Host Pool Hosts Data - $RG / $hostPoolName / $desktopName" -logType debug

    #Get the list of session hosts
    $er = ""
    $hosts = Get-AzWvdSessionHost -ResourceGroupName $RG -HostPoolName $hp -ErrorVariable er
    if ($er) {
        Write-Log "Unable to get Host Pool Hosts data for $RG / $hp - permissions?" -logType fatal
        Write-Log "ERROR: $er" 
        exit 1
    }

    $countHost = 0
    $countDrainModeOn = 0
    $countStatusIsNotAvailable = 0

    Write-Log "Processing Host Pool Hosts Data - Hosts: $hosts" -logType debug

    #Get the list of active hosts powering the desktop
    if ($hosts) {
        #Step trhough each host
        foreach ($hostobject in $hosts) {
            $hostData = @{}
            $countHost ++

            #Get the host and pool name data
            $hostData["hostPoolAndName"] = $hostobject.Name
            $hostData["hostName"] = ((($hostobject.Name).split('/'))[-1]).Trim()     #Get the last element in the array

            #Determine whether users can join it
            $hostData["userCanJoin"] = $hostobject.AllowNewSession
            if (-not $hostData["userCanJoin"]) {
                $countDrainModeOn++
            }

            #Get the heartbeat, state and host status
            $hostData["hostLastHeartbeat"] = $hostobject.LastHeartBeat
            $hostData["hostUpdateState"] = $hostobject.UpdateState
            $hostData["hostLastErrorMessage"] = $hostobject.UpdateErrorMessage
            $hostData["hostStatus"] = $hostobject.Status
            if ($hostData["hostStatus"] -ne "Available") {
                $countStatusIsNotAvailable ++
            }

            #Get the sessions and resource id informaiton
            $hostData["sessions"] = $hostobject.Session
            $hostData["vmssVMID"] = $hostobject.virtualMachineId
            $hostData["vmssVMResourceID"] = $hostobject.resourceId
            $hostData["vmssVMInstanceID"] = (($hostobject.resourceId).split("/"))[-1]

            #Store the hosts by their session count - makes later calculations easier
            #will be used to determine which VM to place in drain mode first.
            if (-Not $hostsBySessionCount[$hostData["sessions"]]) {
                $hostsBySessionCount[$hostData["sessions"]] = @($hostData["hostName"])
            } else {
                $hostsBySessionCount[$hostData["sessions"]] += $hostData["hostName"]
            }
             
            $hostsData[$hostData["hostName"]] = $hostData

        }
        Write-Log "Found $countHost hosts powering desktop $desktop on $($desktopObject.PartitionKey)" -logType debug
        Write-Log "Host pool $($hostData["hostName"]) has: $countDrainModeOn in drain mode, $countStatusIsNotAvailable where status is not 'Available'"

    } else {
        Write-Log "There are no hosts powering Desktop: $desktopName on $($desktopObject.PartitionKey)"
    }

    $returnData["hostCount"] = $countHost
    $returnData["hostsActive"] = $countHost - $countDrainModeOn
    $returnData["hostsInDrainMode"] = $countDrainModeOn
    $returnData["hostsWithStatusNotAvailable"] = $countStatusIsNotAvailable
    $returnData["hostData"] = $hostsData
    $returnData["hostBySessionCount"] = $hostsBySessionCount
    $returnData["poolName"] = $hp
    $returnData["poolRG"] = $RG

    Write-Log "Found $countHost hosts powering desktop $desktop on $($desktopObject.PartitionKey)"

    return $returnData
}

<#
.SYNOPSIS
Get all use users (regardless of state) on the host pool.

.DESCRIPTION
This take the RG, host pool, destop name and hostpool count, and if there are hosts running
then get the users of that host.  It also returns the list of active, disconnected and "other" user types
#>
function Get-HostPoolUsers {
    param (
        [string]$RG,
        [string]$hostPoolName,
        [string]$desktopName,
        [int]$hostPoolCount
    )

    $sessionsData = @()
    $returnData = @{}

    $activeUsers = 0
    $disconnectedUsers = 0
    $usersUnknownState = 0

    Write-Log "Processing Host Pool Host User Data - $RG / $hostPoolName / $desktopName, Host pool count: $hostPoolCount" -logType debug

    #Check if we actually have hosts running - no hosts = no users
    if ($hostPoolCount -gt 0) {
        #Get the users on the AVD hosts
        $poolUsers = Get-AzWvdUSerSession -ResourceGroupName $RG -HostPoolName $hp

        Write-Log "Processing Host Pool Host User Data - Pool Users: $poolUsers" -logType debug

        if ($poolUsers) {
            #Check each user object
            foreach ($userobject in $poolUsers) {
                $userData = @{}
                #Get the host session that the user runs on
                $userData["sessionID"] = $userobject.id

                #Get the details of the session host itself
                $hostData = ((($userobject.name).split("/"))).Trim()
                $userData['hostSessionName'] = $hostData[0]
                $userData['hostSessionHost'] = $hostData[1]
                $userData['hostSessionNumber'] = $hostdata[-1]

                #Get the users details
                $userData["adUserName"] = $userobject.ActiveDirectoryUserName
                $userData["upn"] = $userobject.UserPrincipalName
                $userData["sessionStart"] = $userobject.CreateTime
                
                #Get the state the user in currently in
                $userData["sessionState"] =  $userobject.SessionState
                if ($userData["sessionState"] -eq "Active") {
                    $activeUsers ++
                } elseif ($userData["sessionState"] -eq "Disconnected") {
                    $disconnectedUsers ++
                } else {
                    $usersUnknownState ++
                }

                $sessionsData += $userData

            }
            Write-Log "Active Users: $activeUsers, Disconnected Users: $disconnectedUsers, Unknown State Users: $usersUnknownState on Desktop: $desktopName"

        } else {
            Write-Log "There are no users connected to Desktop: $desktopName on $($desktopObject.PartitionKey)"
        }
    }

    $returnData["poolUserData"] = $sessionsData
    $returnData["poolUserTotal"] = $activeUsers + $disconnectedUsers + $usersUnknownState
    $returnData["usersActive"] = $activeUsers
    $returnData["usersDisconnected"] = $disconnectedUsers
    $returnData["usersUnknownState"] = $usersUnknownState
    

    return $returnData

}

<#
.SYNOPSIS
Gets the lsit of VMSS instances associated with this desktop in this environment

.DESCRIPTION
Takes the RG and VMSS name and get the list of instances and their state running in the
current VMSS.  the main reason why we dont rely on jsut the Host Pool hosts list, is that VMSS
hosts that are currently building or have an issue dont show in the host pool host list
#>
function Get-VMSSInstances {
    param (
        [string]$RG,
        [string]$vmssName
    )
    
    $returnData = @{
        "instanceData" = @()
    }

    Write-Log "Processing VMSS Instances - $RG / $vmssName" -logType debug

    #Get the VMSS and its rolling upgrade state
    $er = ""
    $vmss = Get-AzVmss -ResourceGroupName $RG -VmScaleSetName $vmssName -ErrorVariable er
    if ($er) {
        Write-Log "Unable to get VMSS data for $RG / $vmssName - permissions?" -logType fatal
        Write-Log "$er" 
        exit 1
    }

    $vmssRollingUpgrade = Get-AzVmssRollingUpgrade -ResourceGroupName $RG -VmScaleSetName $vmssName
    Write-Log "Processing VMSS Instances - Rolling Upgrade: $vmssRollingUpgrade" -logType debug

    #Get the VMSS
    $vmssInstances = Get-AzVmssVM -ResourceGroupName $RG -VmScaleSetName $vmssName #-SubscriptionId $subID

    Write-Log "Processing VMSS Instances - instances: $vmssInstances" -logType debug

    $vmssCount = 0
    $vmssProvisioned = 0
    $vmssNonProvisioned = 0
    
    $isScaling = $false

    #Assuming we have a actual VMSS instances, the get the data for the VMSS and all the instances it contains
    if ($vmssInstances) {
        Write-Log "Processing VMSS Instances"
        foreach ($instance in $vmssInstances) {
            $vmssCount ++
            $instData = @{
                "name" = $instance.Name
                "id" = $instance.ID
                "vmID" = $instance.VMID
                "instanceID" = $instance.InstanceId
                "latestModel" = $instance.latestModelApplied
                "vmSize" = $instance.hardwareProfile.vmSize
                "computerName" = $instance.osProfile.computerName
                "provisioningState" = $instance.provisioningState
            }

            if ($instData.provisioningState -eq "Succeeded") {
                $vmssProvisioned ++
            } else {
                if (($instData.provisioningState -eq "Creating") -Or ($instData.provisioningState -eq "Deleting" )) {
                    $isScaling = $true
                }
                $vmssNonProvisioned ++
            }

            Write-Log "VMSS - $($instData.name), $($instData.vmID), $($instData.vmSize), $($instData.provisioningState)" -logType debug

            $returnData["instanceData"] += $instData

        }
    } else {
        Write-Log "No VMSS Instances found in $subId/$RG/$vmssName"
    }

    $returnData["instanceCount"] = $vmssCount
    $returnData["provisionSuccess"] = $vmssProvisioned
    $returnData["provisionOther"] = $vmssNonProvisioned
    $returnData["vmssProvisioningState"] = $vmss.provisioningState
    $returnData["vmssIsScaling"] = $isScaling

    #Bodge!  this piece of code was necessary to get the solution working on a greenfield deploy.
    # if ($vmssRollingUpgrade) {
    #     $returnData["vmssRollingUpgradeState"] = $vmssRollingUpgrade.runningStatus.code
    # } else {
    #     $returnData["vmssRollingUpgradeState"] = "completed"
    # }


    $returnData["vmssName"] = $vmssName
    $returnData["vmssRG"] = $RG

    return $returnData
}

<#
.SYNOPSIS
This function processes the desktop and schedules information to get the expected state at this moment in time

.DESCRIPTION
As part of the startup, this script has already determined which valid desktop (and its associated object) we are running on
so we already know that.  We need to pull the schedules of out the desktop object and get the schedules for it.  we then
need to determine which schedule is relevent for this moment in time.  

At the end we need to return an object that contains the desired state of the Host Pool and VMSS
#>
function Get-ActiveSchedule {
    param (
        [object]$desktopObject,
        [object]$scalerSchedules,
        [object]$scalerBH,
        [hashtable]$config
    )

    #check to make sure we have a desktop object
    if ($desktopObject.length -eq 0) {
        Write-Log "Desktop object is not valid" -logType fatal
        exit 1
    }

    #Note, we need to set a non null entry by default for the active schedule to overcome differences between PS5.1 and PS7+ - used
    #for checking schedule validity further down.
    Write-Log "Determining active schedule for $($desktopObject.PartitionKey) / $($desktopObject.Desktop)"
    $activeSchedule = @{
        "PartitionKey" = "none"
    }

    #Get the schedules from the desktop object (eliminating any start and end white space before split)
    $schedules = (($desktopObject.AppliedSchedules).Trim()).split(",")

    #If we have schedules associated with the desktop
    if ($schedules) {
        Write-Log "Schedules found: $($schedules)"

        #Convert the current UTC time (azure works in UTC) to the current time in the defined timezone taking into account Daylight savings
        $tz = get-timezone -id $timeZone
        $localDate = Get-Date -Date ([System.TimeZoneInfo]::ConvertTime((Get-Date), $tz))
        $nowDay = Get-Date -Date $localDate -Format "dddd"
        $nowTime = Get-Date -Date $localDate -Format "HH:mm"

        Write-Log "Checking if today is a bank holiday"
        $isBankHoliday = Confirm-BankHolidayDates -nowdate (Get-Date -Format "yyyy-MM-dd") -scalerBH $scalerBH

        #Get the possible active schedules
        foreach ($sched in $schedules) {
            $sched = $sched.Trim()
            Write-Log "$($desktopObject.Desktop) - found Schedule: $sched" -logType debug
            $schedData = Get-ScheduleFromScheduleData -schedName $sched -config $config -scalerSchedules $scalerSchedules

            #Check if the schedule actually exists from the table data
            if ($schedData.Count -eq 0) {
                Write-Log "Schedule not found: $sched  - Skipping" -logType warn
                continue
            }

            if (($sched -eq "bankholiday") -And ($isBankHoliday)) {
                #Bank holiday schedule applies
                Write-Log "Bank Holiday Schedule applies - setting active to Bank holiday" -logType warn
                $activeSchedule = $schedData[0]
                break
            } elseif ($sched -eq "bankholiday") {
                Write-Log "Not a bank holiday" -logType debug
                continue
            }

            #We have schedule data (can be more than one with the same name)
            #Note we process all timed entries first, then fallback to a 24hour schedule
            foreach ($schedule in $schedData.timed) {
                #check the recurrance
                if ($schedule.Recurrance) {
                    #expect weekdays, weekends or a comma separated list of days
                    if (-Not (Confirm-RecurranceValid -localDay $nowDay -recurrance $schedule.Recurrance)) {
                        #The recurrance was invalid for local time, so skip it
                        Continue
                    }
                    Write-Log "Recurrance is valid: $($schedule.Recurrance)" -logType debug
                } else {
                    # There is no specific recurrance specified, so it applies every day
                }

                if ($schedule.TimeStart -And $schedule.TimeEnd) {
                    #Expect an active time slot to sit between these two times
                    $isValid = Confirm-TimeValid -timeLocal $nowtime -timeStart (Get-Date -Date $schedule.TimeStart) -timeEnd (Get-Date -Date $schedule.TimeEnd)
                    if ($isValid -eq $true) { 
                        Write-Log "Schedule Match - The current time ($nowtime) is between: $($schedule.timestart) and $($schedule.timeend)" -logType debug
                        $activeSchedule = $schedule
                    } else {
                        Write-Log "Schedule No Match - The current time ($nowtime) is NOT between: $($schedule.timestart) and $($schedule.timeend)" -logType debug
                        #The time slot is invalid for local time, so skip it
                        Continue 
                    }
                    

                } else {
                    # there is no specific start or end time (or timeStart/timeEnd is missing) so assume it is a 24h timeframe
                    # we should not technically be here!
                }

                #As we have a valid schedule, and schedules are processed in order, kill the foreach loop
                if ($activeSchedule.PartitionKey -ne "none") {
                    break
                }
            }
            
            Write-Log "Checking if we have a schdule - $($activeSchedule) and $($activeSchedule.length)" -logType debug
            if ($activeSchedule.PartitionKey -ne "none") { 
                Write-Log "We do indeed have a schedule that is live - $($activeSchedule)" -logType debug
                break
            } 

            #So we have no time based schedule so lets check if we have a fallback schedule
            foreach ($schedule in $schedData.fallback) {
                #check the recurrance
                if ($schedule.Recurrance) {
                    #expect weekdays, weekends or a comma separated list of days
                    if (-Not (Confirm-RecurranceValid -localDay $nowDay -recurrance $schedule.Recurrance)) {
                        Write-Log "Fallback Recurrance not valid for this schedule: $($schedule.Recurrance)" -logType debug
                        #The recurrance was invalid for local time, so skip it
                        Continue
                    }
                    Write-Log "Fallback Schdule Recurrance is valid: $($schedule.Recurrance)" -logType debug
                } else {
                    # There is no specific recurrance specified, so it applies every day
                }

                #As it is a 24h fallback schedule we dont worry about checking its time so we know it is active.
                $activeSchedule = $schedule

                #As we have a valid schedule, and schedules are processed in order, kill the foreach loop
                break
            }
            
        }
    }

    #Okay so we dont have any schedules for the desktop, so fall back to the default schedule
    if ($activeSchedule.PartitionKey -eq 'none') {
        Write-Log "No schedule found - falling back to default schedule" -logType warn

        #Get the default schedule
        $defaultSchedData = Get-ScheduleFromScheduleData -schedName 'default' -config $config -scalerSchedules $scalerSchedules
        $activeSchedule = ($defaultSchedData.all)[0]
    } else {
        Write-Log "Schedule selected: $($activeSchedule.PartitionKey)" -logType good
    }

    #Fill in some details for the 24h schedules if they are missing
    if (-Not $activeSchedule.TimeStart) {$activeSchedule.TimeStart = "00:00"}
    if (-Not $activeSchedule.TimeEnd) {$activeSchedule.TimeEnd = "24:00"}

    return $activeSchedule

}

<#
.SYNOPSIS
Get the list of bank holidays from the UK Government website
It might be worth internalising this in a table, updating every month or so, instead of constantly calling out

.DESCRIPTION
Calls the UK government website API to get a list of the bank holidays for the UK

TODO: Get this only once every month and store it somewhere - perhaps a storage table and reference it from there instead?

#>
function Confirm-BankHolidayDates {
    Param (
        [string]$nowdate = (Get-Date -Format "yyyy-MM-dd"),
        [object]$scalerBH
    )

    foreach ($bhObject in $scalerBH) {
        if ($bhObject.RowKey -eq $nowdate) {
            Write-Log "Today is a bank holiday - $($bhObject.PartitionKey)" -logType good
            return $true
        } 
    }

    return $false
}

<#
.SYNOPSIS
This function takes the recurrance and determines whether it is valid against the day provided

.DESCRIPTION
Check the recurrance (e.g. weekdays, day list, weekend etc) is valid for the current date and time.
Returns a simple true or false

#>
function Confirm-RecurranceValid {
    param (
        [string]$localDay = (Get-Date -Format "dddd"),
        [string]$recurrance
    )

    $weekdays = @("Monday","Tuesday","Wednesday","Thursday","Friday")
    $weekend = @("Saturday","Sunday")

    $result = $false

    if ($recurrance) {
        if (($recurrance -eq "weekdays") -And ($weekdays.Contains($localDay))) {
            $result = $true
        } elseif (($recurrance -eq "weekend") -And ($weekend.Contains($localDay))) {
            $result = $true
        } else {
            #Break the recurrance down on a comma
            foreach ($recDay in $recurrance.split(',')) {
                $recDay = $recDay.Trim()
                if ($weekdays.Contains($recDay) -Or $weekend.Contains($localDay)) {
                    $result = $true
                    break
                }
            }
        }
    } else {
        #No recurrance specified, which means that it always applies
        return $true
    }

    return $result
}

<#
.SYNOPSIS
Verify of the local time provided sits between the start and end times of the schedule

.DESCRIPTION
check the current time against the provided schedule and determine whether it is valid
returns a simple true or false
#>
function Confirm-TimeValid {
    param (
        [datetime]$timeLocal,
        [datetime]$timeStart,
        [datetime]$timeEnd
    )

    #Get the times in DateTime format
    $timeStart = Get-Date -Date $timeStart
    $timeEnd = Get-Date -Date $timeEnd
    $timeLocal = Get-Date -Date $timeLocal

    Write-Log "Determine if Schedule start and end time is valid" -logType info
    Write-Log "Time Start Specified: $timeStart"
    Write-Log "Time End Specified: $timeEnd"
    Write-Log "Local Time on server: $timeLocal"

    #check if the start time is "younger" than the local time
    $localStartDiff = $timeLocal - $timeStart

    Write-Log "Time diff 1: $localStartDiff and $($localStartDiff.TotalSeconds)" -logType debug

    #Determine if the start time is valid
    if ($localStartDiff.TotalSeconds -lt 0) {
        #No point in going on as we have not yet reached the start time for this schedule
        Write-Log "timeLocal ($timeLocal) is earlier than timeStart ($timeStart)" -logType debug
        return $false
    } else {
        Write-Log "timeLocal ($timeLocal) is later than timeStart ($timeStart)" -logType debug
    }

    #Check if timeEnd is less than or equal to timeStart as that means it is rolling over midnight, so add a day
    $startEndDiff = $timeEnd - $timeStart
    Write-Log "Time diff 2: $startEndDiff and $($startEndDiff.TotalSeconds)" -logType debug

    if ($startEndDiff.TotalSeconds -lt 0) {
        Write-Log "Schedule day rollover detected" -logType debug
        $timeEnd = (Get-Date -Date $timeEnd).AddDays(1)
    }

    #Now check if the current local time is before the end time
    $localEndDiff = $timeEnd - $timeLocal
    Write-Log "Time diff 3: $localEndDiff and $($localEndDiff.TotalSeconds)" -logType debug

    if ($localEndDiff.TotalSeconds -lt 0) {
        #No point in going on as we have exceeded the end time of this schedule
        Write-Log "timeLocal ($timeLocal) is later than timeEnd ($timeEnd)" -logType debug
        return $false
    }
    else {
        Write-Log "timeLocal ($timeLocal) is has not reached timeStart ($timeStart)" -logType debug
    }

    return $true
}

<#
.SYNOPSIS
Simple function that gets and logs the status of the service

.DESCRIPTION
Pulls together the list of service data and logs it.
#>
function Get-ServiceStatus {
    param (
        [object]$desktopObject,
        [object]$activeSchedule,
        [object]$serviceData
    )

    $vmssData = $serviceData.vmssData
    #$hpData = $serviceData.hostPoolData
    $hpHostData = $serviceData.hostPoolHostData
    $hpUserData = $serviceData.userData

    Write-Log "Updating Desktop: $($desktopObject.Desktop) in Environment: $($desktopObject.PartitionKey)"
    Write-Log "Schedule in use: $($activeSchedule.PartitionKey), Starts: $($activeSchedule.TimeStart), Ends:$($activeSchedule.TimeEnd), Recurring: $($activeSchedule.Recurrance)"
    
    if ($vmssData.instanceCount -gt 0) {
    Write-Log "Current State VMSS: InstanceCount: $($vmssData.instanceCount), Provisioning Success: $($vmssData.provisionSuccess), Provisioning Other: $($vmssData.provisionOther)"
    } else {
        Write-Log "Current State VMSS: Scaled to Zero"
    }

    if ($hpHostData.hostCount -gt 0) {
        Write-Log "Current State Host Pool: Host Count: $($hpHostData.hostCount), Hosts in Drain Mode: $($hpHostData.hostsInDrainMode), Hosts with status unavailable: $($hpHostData.hostsWithStatusNotAvailable)"
    } else {
        Write-Log "Current State Host Pool: No Hosts available"
    }

    if ($hpUserData.poolUserTotal -gt 0) {
        Write-Log "Current State Host Pool Users: Active Users: $($hpUserData.usersActive), Disconnected Users: $($hpUserData.usersDisconnected), Unknown State Users: $($hpUserData.usersUnknownState)"
    } else {
        Write-Log "Current State Host Pool Users: No users logged in"
    }
}

<#
.SYNOPSIS
Determine the desired state and the plan to reach it, then enact that plan

.DESCRIPTION
This is the main function that manages the scaling of the service.
#>
function Update-Scaler {
    param (
        [object]$desktopObject,
        [object]$activeSchedule,
        [object]$serviceData
    )

    #Get the host data
    $hpHostData = $serviceData.hostPoolHostData
    $hpUserData = $serviceData.userData

    Write-Log "Scaler checking for updates $($desktopObject.Desktop) in Environment: $($desktopObject.PartitionKey)"

    #check if the schedule is set to "manual".  If it is do nothing as it is up to the user to manage the schedule
    if (($activeSchedule.PartitionKey).toLower() -eq "manual") {
        Write-Log "Schedule is Set to MANUAL.  No scaling will take place." -logType warn
        return
    }

    #Given the schedule, check what the capacity should be
    $vmCountMin = [math]::ceiling($activeSchedule.CapacityMin/$desktopObject.VMCapacity)
    $vmCountMax = [math]::ceiling($activeSchedule.CapacityMax/$desktopObject.VMCapacity)

    Write-Log "Minimum Machine count: $vmCountMin, Maximum machine count: $vmCountMax"

    #Get the number of VMs that are required for the number of users within the current schedule
    $vmCountUserCount = $vmCountMin
    if ($hpUserData.poolUserTotal -gt 0) {
        $vmCountUserCount = ([math]::ceiling(($hpUserData.poolUserTotal/$desktopObject.VMCapacity)+($activeSchedule.CapacityMin/$desktopObject.VMCapacity)))
    } 

    #Determine whether we have enough hosts for the current schedule/number of users/space capacity
    #First check if we need to scale up
    Write-Log "Users logged in: $($hpUserData.poolUserTotal), requiring $vmCountUserCount Pool Hosts including required spare capacity $($activeSchedule.CapacityMin)"
    if ($vmCountUserCount -gt $hpHostData.hostsActive) {
        #We are using hosts active, because other hosts cannot accept users
        $scaleUpBy = $vmCountUserCount - $hpHostData.hostsActive
        if ($scaleUpBy -gt $activeSchedule.MaxInstanceScaling) {
            #Restruct the number of machines that can be scaled up by in any one action
            $scaleUpBy = $activeSchedule.MaxInstanceScaling
        } 
        Write-Log "SCALE UP required, From $($hpHostData.hostCount) to $($vmCountUserCount+$hpHostData.hostsInDrainMode) ($scaleUpBy), Hosts in Drain Mode $($hpHostData.hostsInDrainMode)"
        
        #Do the Scale Up 
        $result = Start-ScaleUp $scaleUpBy $desktopObject $activeSchedule $serviceData
        Write-output "Scale Up Result: $result"

        if (-Not $result) {
            Write-Log "Scale up not completed on this run"
        }

    } elseif ($vmCountUserCount -lt $hpHostData.hostsActive) {
        #Okay so we have too many hosts for the required user count / schedule, so scale down
        $scaleDownBy =  $hpHostData.hostsActive - $vmCountUserCount
        #Restrict the maximum scale down operations in any one action
        if ($scaleDownBy -gt $activeSchedule.MaxInstanceScaling) {
            #Restruct the number of machines that can be scaled up by in any one action
            $scaleDownBy = $activeSchedule.MaxInstanceScaling
        }
        Write-Log "SCALE DOWN required, From $($hpHostData.hostsActive) to $vmCountUserCount ($scaleDownBy)"
        #Do scale down
        $result = Start-ScaleDown $scaleDownBy $serviceData

        if (-Not $result) {
            Write-Log "Scale down not completed on this run"
        }

    } else {
        #We are where we need to be, do nothing.
        Write-Log "No scale required: $vmCountUserCount and $($hpHostData.hostsActive)" 
    }

    #Tidy any hosts that are sitting in drain mode with zero users
    Write-Log "Clean up Session Hosts in Drain mode with zero users" -logType good
    Start-TidyDrainedSessionHosts $desktopObject $serviceData
    Write-Log "Clean up Session Hosts in Drain mode with zero users - completed" -logType good
}

<#
.SYNOPSIS
Scale up the VMSS soltuion to create more host pool hosts

.DESCRIPTION
Start scaling up the solution to the required number of hosts, but is constrained by the maximum number of hosts
that scan be scaled up in any one run of this command.

.NOTES
the thought has occurred as to why you would not simply take any machine that is current in Drain Mode back out of drain mode
into active service rather than spool up a new VMSS VM.  The issue is that we do not know why the machine was put into
drain mode in the first place.  Was it the Scaler, was it a machine that was manually placed in drain mode because of an issue,
is it part of the rolling upgrade to a new image?  If a way can be implemented to track the reason for drain mode, then taking
a host out of drain mode might become possible at least for a limited number of hosts.
#>
function Start-ScaleUp {
    param (
        [int]$scaleUpBy,
        [object]$desktopObject,
        [object]$activeSchedule,
        [object]$serviceData
    )

    Write-Log "Scale Up triggered"

    $vmssData = $serviceData.vmssData
    $hpHostData = $serviceData.hostPoolHostData

    #Get the maximum number of VMs that are permitted for this host pool
    $vmCountMax = [math]::ceiling($activeSchedule.CapacityMax/$desktopObject.VMCapacity)

    Write-Log "Maximum VMs permitted: $vmMaxCount"

    #check to make sure that VMSS is ready
    if (([string]$vmssData.vmssProvisioningState).ToLower() -ne "succeeded") {
        Write-Log "VMSS is busy.  VMSS is not ready (provisioning state is: $($vmssData.vmssProvisioningState))." -logType info
        return $false
    }

    #Check the VMs to see if the VMSS is scaling
    if ($vmssData.vmssIsScaling) {
        Write-Log "VMSS is busy.  Scaling in operation." -logType info
        return $false
    }

    #Check for any rolling upgrades
    # $rollUpgradeState = ([string]$vmssData.vmssRollingUpgradeState).ToLower()
    # if ( ($rollUpgradeState -ne "completed") -And ($rollUpgradeState -ne "cancelled")) {
    #     Write-Log "VMSS is busy.  Rolling Upgrades in operation. Not Scaling" -logType info
    #     return $false
    # }

    #check to make sure that VMSS has not already hit ceiling limit
    if ($vmssData.instanceCount -ge $vmCountMax) {
        Write-Log "VMSS is at maximum capacity - unable to scale" -logType warn
        return $false
    } else {
        if (($vmssData.instantcount+$scaleUpBy) -ge $vmCountMax) {
            Write-Log "VMSS near maximum capacity - unable to scale $scaleUpBy VM units.  Scaling to maximum" -logType warn
            $scaleUpBy = $vmCountMax - $vmssData.instantcount
        }
    }

    #Check to make sure that the VMSS is not more than the maximum number of operations ahead of the Host Pool
    $poolVsVMSSCount = $vmssData.instantcount - $hpHostData.hostCount
    if ($poolVsVMSSCount -ge $activeSchedule.MaxInstanceScaling) {
        Write-Log "VMSS is already $($activeSchedule.MaxInstanceScaling) instances ahead of Host Pool.  Not Scaling to prevent potential runaway scenario" -logType warn
        return $false
    }

    #Sanity check that ScaleUpBy
    if ($scaleUpBy -gt $activeSchedule.MaxInstanceScaling) {
        Write-Log "Something has gone wrong with the scaler figures.  Cannot scale up by $scaleUpBy.  Exiting" -logType fatal
        exit 1
    }

    #Do the SCALE UP
    Write-Log "Scaling up by $scaleUpBy instances: $($vmssData.vmssName)"
    $capacity = ($vmssData.instanceCount + $scaleUpBy)
    if ($dryRun) {
        Write-Log "DRYRUN: No action taken" -logType warn
    } else {
        $er = ""
        $result = Update-AzVmss -ResourceGroupName $vmssData.vmssRG -VMScaleSetName $vmssData.vmssName -SkuCapacity $capacity -AsJob -ErrorVariable er
        if ($er) {
            Write-Log "Unable to scale up the VMSS - permissions?" -logType error
            Write-Log "ERROR: $er"
        }
        if ($result.State -ne "Running") {
            Write-Log "VMSS has failed to scale up" -logType warn
        } else {
            Write-Log "Scale Up in progress"
        }
    }
    return $true
}

<#
.SYNOPSIS
Put a host pool host into drain mode and, if a host pool host is in drain mode without any users on it, remove it from
the pool and VMSS

.DESCRIPTION
Scale down is bit of a misnomer - what it does it enable the Drain Mode on machines with the least number and then once the machine has
zero users, the cleanup function does the actual scale down of VMSS

.NOTES
For normal operations, under no circumstances should a Host be removed from operation why there are still users using it, hence drain mode
The only exception is when $force is set to true.  This would be done, for example, when there was a forced scale to zero scheduled.
#>
function Start-ScaleDown {
    param (
        [int]$scaleDownBy,
        [object]$serviceData
    )

    Write-Log "Drain mode enable triggered"

    $hpHostData = $serviceData.hostPoolHostData
    
    #Scan through the hosts and determine which host has the least number of users.  Enable drain mode.
    Write-Log "Step trhough hosts based on their session count - min to max" -logType debug
    $draincount = 0
    foreach ($sessionData in (($hpHostData.hostBySessionCount).GetEnumerator() | Sort-Object -Property Name)) {
        Write-Log "Got session count $($sessionData.name) is $($sessionData.value)" -logType debug
        foreach ($hpHost in $sessionData.value) {
            #Is the host already in drain mode? If so skip
            if ($hpHostData.hostData.$hpHost.userCanJoin) {
                Write-Log "Enabling Drain Mode on $hpHost which has $($hpHostData.hostData.$hpHost.sessions) sessions"
                if ($dryRun) {
                    Write-Log "DRYRUN: No action taken" -logType warn
                } else {
                    $er = ""
                    Update-AzWvdSessionHost -ResourceGroupName $hpHostData.poolRG -HostPoolName $hpHostData.poolName -Name $hpHost -AllowNewSession:$false -ErrorVariable er
                    if ($er) {
                        Write-Log "Unable to put host pool host into drain mode - permissions?" -logType error
                        Write-Log "ERROR: $er"
                    }
                }
                $draincount ++
            }
            
            #Okay we have put the required number of machines in drain mode
            if ($draincount -eq $scaleDownBy) { 
                Write-Log "Drain Count Reached $draincount = $scaleDownBy" -logType debug
                break
            }
        }
    }

    Write-Log "Drain mode enable completed"

    return $true
}

<#
.SYNOPSIS
Scans trhough the list of host pools in drain mode with zero users and removes them from the host
Pool AND the VMSS

.DESCRIPTION
This carries out a number of cleanup tasks.  it will do the following:
 - Remove Hosts in the pool that are currently in drain mode AND have no users
 - Check if there are any VMSS instances that are not in the pool and are in a success state,
   give them a cycle of 10 (of 5 seconds each cycle) and if still not in the pool, remove it
- check if there are orphaned host pool session hosts and remove them
#>
function Start-TidyDrainedSessionHosts {
    param (
        [object]$desktopObject,
        [object]$serviceData
    )
    $hpHostsData = $serviceData.hostPoolHostData
    $vmssData = $serviceData.vmssData

    #Scan through all drain mode hosts and determine if there are any users remaining.  If not, then remove the host.
    #Not this will not remove any machines that have been placed into drain mode in  this cycle to allow them to settle
   
    $doneSomething = $false
    
    #Step trhough each host pool session
    foreach ($hpHostSessionData in (($hpHostsData.hostData).GetEnumerator())) {
        $hpHostName = $hpHostSessionData.key
        $hpHostdata = $hpHostSessionData.value

        #If the number of sessions are zero AND the host is in drain mode then remove the host pool session AND the VMSS instance
        if (($hpHostData.sessions -eq 0) -And ($hpHostData.userCanJoin -eq $false)) {
            Write-Log "Removing session host: $($hpHostName) from Pool: $($hpHostsdata.poolName) - Active sessions: $($hpHostData.sessions)"
            
            #Remove the host pool session host
            if ($dryRun) {
                Write-Log "DRYRUN: Remove Pool Host - No action taken" -logType warn
            } else {
                $er = ""
                Remove-AzWvdSessionHost -ResourceGroupName $hpHostsdata.poolRG -HostPoolName $hpHostsdata.poolName -Name $hpHostName -ErrorVariable er
                if ($er) {
                    Write-Log "Unable to remove Host Pool Session Host - permissions?" -logType error
                    Write-Log "ERROR: $er"
                }
            }

            $vmssResourceId = $hpHostData.vmssVMResourceID
            Write-Log "Removing session host from VMSS: $vmssResourceId and $($hpHostdata.vmssVMInstanceID)"

            #Remove the VMSS instance
            if ($dryRun) {
                Write-Log "DRYRUN: Remove VMSS Instance - No action taken" -logType warn
            } else {
            
                $er = ""
                $result = Remove-AzVmss -ResourceGroupName $vmssData.vmssRG -VMScaleSetName $vmssData.vmssName -Force -InstanceId $hpHostdata.vmssVMInstanceID -AsJob -ErrorVariable er
                if ($er) {
                    Write-Log "Unable to remove VMSS Instance - permissions?" -logType error
                    Write-Log "ERROR: $er"
                }

                if ($result.State -ne "Running") {
                    Write-Log "VMSS has failed to scale down" -logType warn
                } else {
                    Write-Log "Removing VMSS Host: $($vmssData.vmssName)"
                }

                $doneSomething = $true
            }

        } elseif (([string]$hpHostData.hostStatus).ToLower() -eq "unavailable") {
            if ($scaleTestMode) {
                #We are running is scale test mode, so dont worry about the health of the hosts
                Write-Log "SCALE TEST MODE: Remove Pool Host called for unavailable hosts ($hpHostName) - No action taken" -logType warn

            } else {
                #Check for broken Host pool hosts (e.g. VMSS supporting object is missing) and remove them - ignore this step if $ScaleTestMode global is set to true
                Write-Log "Removing session host: $($hpHostName) from Pool: $($hpHostsdata.poolName) - Active sessions: $($hpHostData.sessions) - Status: Unavailable" -logType warn
                
                if ($dryRun) {
                    Write-Log "DRYRUN: Remove Pool Host - No action taken" -logType warn
                } else {
                    $er = ""
                    Remove-AzWvdSessionHost -ResourceGroupName $hpHostsdata.poolRG -HostPoolName $hpHostsdata.poolName -Name $hpHostName -ErrorVariable er
                    if ($er) {
                        Write-Log "Unable to remove orphened Host Pool Session Host - permissions?" -logType error
                        Write-Log "ERROR: $er"
                    }
                    $doneSomething = $true
                }
            }
        }
    }

    #Check VMSS itself and compare with Host Pool.  Look for any machine that is in a running state for more than 20 mins and
    #has not been added to the host pool.  Remove them
    if ($hpHostsData.hostCount -eq $vmssData.provisionSuccess) {
        Write-Log "Pool and VMSS are in balance"
    } elseif ($hpHostsData.hostCount -lt $vmssData.provisionSuccess) {
        #If the host pool and VMSS are out of balance determine what the issue is and resolve it.
        Write-Log "Pool and VMSS are not currently in balance - there are more VMSS Instances that currently in Pool - checking"

        #Check each VMSS instance to see if any of them are busy
        foreach ($instance in $vmssData.instanceData) {
            Write-Log "Checking VMSS Instance: $($instance.name)"
            
            #ignore if in a creating state (though we should not be here if we are)
            if ($instance.provisioningState -eq "Succeeded") {

                #Now check the live data over the next 50 seconds to see if it pops up
                $count = 0
                $inHostPool = $false

                #cycle 10 times with a 5 second delay and wait to see if the VMSS (which is in a success state) appers in the host pool
                while ($count -lt 10) {
                    $vmHpData = Get-AzWvdSessionHost -ResourceGroup $hpHostsdata.poolRG -hostPoolName $hpHostsdata.poolName
                    foreach ($hpHost in $vmHpData) {
                        $instantID = (($hpHost.ResourceId).Split("/"))[-1]
                        $hpInstanceName = "$($vmssData.vmssName)_$($instantID)"
                        if ($instance.name -eq $hpInstanceName) {
                            Write-Log "Match - $($instance.name) in $($hpHostsdata.poolName) found" -logType debug
                            $inHostPool = $true
                            break
                        }
                    }
                    if ($inHostPool) {
                        break 
                    }
                    
                    Write-Log "No match - Retry $($count+1) - $($instance.name) in $($hpHostsdata.poolName)" -logType debug
                    $count++
                    Start-Sleep -Seconds 5
                }

                #Still not in the host pool, delete it.
                if (-Not $inHostPool) {
                    $instanceid = (($instance.name).split("_"))[-1]
                    Write-Log "Deleting VMSS VM that is not part of the Host Pool: $($instance.name)  ID: $instanceid" -logType warn

                    if ($dryRun) {
                        Write-Log "DRYRUN: Remove VMSS Instance - No action taken" -logType warn
                    } else {
                        $er = ""
                        $result = Remove-AzVmss -ResourceGroupName $vmssData.vmssRG -VMScaleSetName $vmssData.vmssName -Force -InstanceId $instanceid -ErrorVariable er
                        if ($er) {
                            Write-Log "Unable to remove VMSS Instance - permissions?" -logType error
                            Write-Log "ERROR: $er"
                        }
                        if ($result.State -eq "Running") {
                            Write-Log "VMSS has failed to remove redundant instance" -logType warn
                        } else {
                            Write-Log "Removing VMSS Host: $($vmssData.vmssName)"
                        }
                    }
                }
            }

        }
    }


    if (-Not $doneSomething) {
        Write-Log "No cleanup required"
    }

}


<#
.SYNOPSIS
Gets the schedule and desktop information from the Azure Storage Table
#>
function Get-DataFromTable {
    param (
        [hashtable]$config #,
    )

    $returnData = @{}

    #Get the schedule data
    $scheduleConfig = $config.tables.schedules
    $storageAccountKeys = Get-AzStorageAccountKey -ResourceGroupName $scheduleConfig.RG -Name $scheduleConfig.storageName

    $storageContext = New-AzStorageContext -StorageAccountName $scheduleConfig.storageName -StorageAccountKey $storageAccountKeys[0].Value
    $azureTable = Get-AzStorageTable -Context $storageContext -Name $scheduleConfig.tableName
    $returnData.schedules = Get-AzTableRow -Table $AzureTable.CloudTable -Top 1000

    #Get the desktop table
    $desktopConfig = $config.tables.desktops
    $storageAccountKeys = Get-AzStorageAccountKey -ResourceGroupName $desktopConfig.RG -Name $desktopConfig.storageName

    $storageContext = New-AzStorageContext -StorageAccountName $desktopConfig.storageName -StorageAccountKey $storageAccountKeys[0].Value
    $azureTable = Get-AzStorageTable -Context $storageContext -Name $desktopConfig.tableName
    $returnData.desktops = Get-AzTableRow -Table $AzureTable.CloudTable

    #Get the Bank holiday data
    $bhConfig = $config.tables.bankholidays
    $storageAccountKeys = Get-AzStorageAccountKey -ResourceGroupName $bhConfig.RG -Name $bhConfig.storageName

    $storageContext = New-AzStorageContext -StorageAccountName $bhConfig.storageName -StorageAccountKey $storageAccountKeys[0].Value
    $azureTable = Get-AzStorageTable -Context $storageContext -Name $bhConfig.tableName
    $returnData.bankholidays = Get-AzTableRow -Table $AzureTable.CloudTable


    return $returnData
}

<#
.SYNOPSIS
Gets the schedule by name from data recovered from the storage table
#>
function Get-ScheduleFromScheduleData {
    param (
        [hashtable]$config,
        [object]$scalerSchedules,
        [string]$schedName = 'default'
    )

    $schedules = @()
    $timedSchedList = @()
    $fallbackSchedules = @()

    #Search the schedules for any partitionkey that matches the desktop name
    foreach ($sched in $scalerSchedules) {
        if (($sched.PartitionKey).ToLower() -eq $schedName.ToLower()) {
            $schedules += $sched
            if ($sched.TimeStart -And $sched.TimeEnd) {
                Write-Log "Timed schedule found: $($sched.TimeStart) To $($sched.TimeEnd)" -logType debug
                $timedSchedList += $sched
            } else {
                # there is no specific start or end time (or timeStart/timeEnd is missing) so assume it is a 24h timeframe
                Write-Log "24h fallback schedule found" -logType debug
                $fallbackSchedules += $sched
            }
        }
    }

    $schedData = @{
        "all" = $schedules
        "timed" = $timedSchedList
        "fallback" = $fallbackSchedules
    }

    return $schedData

}

#start the script running
Write-Log "Starting Run" -logType good
Start-Main -env $env.toLower() -desktop $desktop -doLogin $doLogin -scalerEnv $scalerEnv