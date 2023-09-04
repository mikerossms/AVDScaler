#Enables or disables all the schdules for a particular Automation Account
param (
    [string]$env,
    [bool]$schedulesEnabled = $true,
    [bool]$doLogin = $true
)

$RG = "EHP-RG-SCALER-$env".ToUpper()
$aaName = "ehp-aa-ehpscaler-$env".ToLower()

#change these to match your environment - can both be wtihin the same subscription
#!!!CONFIG!!!
$environments = @{
    "dev" = @{
        "subName" = "<change me>"
        "subID" = "<change me>"
    }
    "prod" = @{
        "subName" = "<change me>"
        "subID" = "<change me>"
    }
}

$subid = $environments.$env.subID
$subname = $environments.$env.subName

if ($doLogin) {
    Write-Host "Logging into Azure - User interactive mode" -ForegroundColor Green
    $cnx = Connect-AzAccount
}

Write-Host "Changing subscription to: $subname ($subid)" -ForegroundColor Green
$subContext = Set-AzContext -Subscription $subid

if ($subContext.subscription.id -ne $subid) {
    Write-Host "Cannot change to subscription: $subname ($subid)" -ForegroundColor Red
    exit 1
}

$schedules = az automation schedule list --automation-account-name $aaName --resource-group $RG | ConvertFrom-Json
if ($schedules.count -gt 0) {
    Write-Host "Updating Schedules" -ForegroundColor Green
    foreach ($sched in $schedules) {
        if (($sched.name).StartsWith("AVDScaler")) {
            if ($sched.isEnabled -ne $schedulesEnabled) {
                Write-Host " - Changing $($sched.name) from $($sched.isEnabled) to $schedulesEnabled"
                $schedStatus = (az automation schedule update --automation-account-name $aaName --resource-group $RG --name $sched.name --is-enabled $schedulesEnabled | ConvertFrom-Json).isEnabled
                if ($schedStatus -ne $schedulesEnabled) {
                    Write-Host "Failed to set schedule enabled/disabled status: $($sched.name)" -ForegroundColor Yellow
                } else {
                    Write-Host "Failed to set schedule enabled/disabled status: $($sched.name)" -ForegroundColor Green
                }
            }
        }
    }
}