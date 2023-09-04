<#
.SYNOPSIS
This script is the runbook orchestrator kicking off a runbook workflow which in turn kicks off the AVD scaler
The script runs on a schedule as a runbook.  It is not indended to be run manually

.DESCRIPTION
The script takes a single parameter - runEnvironment which is mandatory.  This is either "coredev" or "coreprod"
and indicates the environment that the scheduler will get appropriate data for.  BE CAREFUL to specify the correct
environment - coreprod will affect all PRODUCTION AVD services.
#>

param (
    [Parameter(Mandatory)]
    [string]$runEnvironment
)

$runEnvironment = $runEnvironment.ToLower()

#configure the subscriptions
#!!!CONFIG!!!
$environments = @{
    "coredev" = @{
        "subName" = "<change me>"
        "subID" = "<change me>"
        "RG" = "EHP-RG-SCALER-DEV"
        "storageName" = "ehpstscalerdev"
        "storageTableDesk" = "ScalerDesktops"
        "aaAccount" = "ehp-aa-ehpscaler-dev"
        "rbParallelRunnerName" = "AVDScalerParallelRun"
        "rbAVDScalerName" = "AVDAutoScaler"
    }
    "coreprod" = @{
        "subName" = "<change me>"
        "subID" = "<change me>"
        "RG" = "EHP-RG-SCALER-PROD"
        "storageName" = "ehpstscalerprod"
        "storageTableDesk" = "ScalerDesktops"
        "aaAccount" = "ehp-aa-ehpscaler-prod"
        "rbParallelRunnerName" = "AVDScalerParallelRun"
        "rbAVDScalerName" = "AVDAutoScaler"
    }
}

$tenantID = "<change me>"
$subid = $environments.$runEnvironment.subID
$subname = $environments.$runEnvironment.subName

#Validate the subscription id
if (-Not $subid) {
    Write-Error "ERROR: subscription ID is missing"
    exit 1
}

function Get-SAKey {
    param (
        [string]$SAName,
        [string]$RG,
        $ctx
    )

    $SAKeys = $null
    [int]$attempts = 0
    while ($attempts -lt 10) {
        try {
            $SAKeys = Get-AzStorageAccountKey -DefaultProfile $ctx -ResourceGroupName $RG -Name $SAName -ErrorVariable er -ErrorAction Stop
            break
        }
        catch {
            Start-Sleep 5
        }
        $attempts++
    }

    if ($er) {
        Write-Error "Unable to get the keys for storage account: $SAName"
        Write-Error "ERROR: $er"
        Exit 1
    }

    return $SAKeys
}

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process

try {
    $AzureContext = (Connect-AzAccount -Identity -SubscriptionId $subid -ErrorAction Stop).context
}
catch {
    Start-Sleep 15
    $AzureContext = (Connect-AzAccount -Identity -SubscriptionId $subid -ErrorAction SilentlyContinue).context
}

if ($AzureContext.Tenant.Id -ne $tenantID) {
    Write-Error "ERROR: Cannot log in with Managed System credentials"
    exit 1
}

if ($AzureContext.subscription.id -ne $subid) {
    Write-Error "ERROR: Cannot change to subscription: $subname ($subid)" 
    exit 1
}

#Break out some of the variables
$RG = $environments.$runEnvironment.RG
$aaName = $environments.$runEnvironment.aaAccount
$rbParallelName = $environments.$runEnvironment.rbParallelRunnerName
$rbScalerName = $environments.$runEnvironment.rbAVDScalerName

#Get the storage account context and Desktops data
$storageAccountKeys = Get-SAKey -ctx $AzureContext -RG $RG -SAName $environments.$runEnvironment.storageName
$storageContext = New-AzStorageContext -StorageAccountName $environments.$runEnvironment.storageName -StorageAccountKey $storageAccountKeys[0].Value
$azureTable = Get-AzStorageTable -DefaultProfile $AzureContext -Context $storageContext -Name $environments.$runEnvironment.storageTableDesk
$desktops = Get-AzTableRow -Table $AzureTable.CloudTable

#Create a structured list of the required desktop data, limiting it to the run environment associated with this AA
$desktopsData = @()
Foreach ($deskobj in $desktops) {
    if ((($deskobj.RunEnvironment).toLower()) -eq $runEnvironment) {
        $data = @{
            env = $deskobj.PartitionKey.ToLower()
            desktop = $deskobj.Desktop.ToLower()
            scalerEnv = $runEnvironment
        }
        $desktopsData += $data
    }
}

#build the params required for the starting the parallel running workflow runbook
$rbParams = @{
    "aaName" = $aaName
    "rbScaler" = $rbScalerName
    "rg" = $RG
    "subid" = $subid
    "desktops" = $desktopsData
}

#start the workflow Runbook
Start-AzAutomationRunbook -DefaultProfile $AzureContext -AutomationAccountName $aaName -Name $rbParallelName -ResourceGroupName $RG -Parameters $rbParams -Wait