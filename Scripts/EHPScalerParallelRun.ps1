workflow EHPScalerParallelRun {
    # this script takes the details of the Automation account and parallel runbook as well as the desktops
    # data provided by the scheduler and runs (in parallel) all the scalers for the list of desktop provided
    Param (
        [string]$aaName,
        [string]$rbScaler,
        [string]$rg,
        [string]$subid,
        [array]$desktops
    )
    #
    Connect-AzAccount -Identity
    $AzureContext = Set-AzContext -SubscriptionId $subid

    #Parallel run all the scalers
    Foreach -Parallel ($deskobj in $desktops) {
        InlineScript {
            #Get up the vars needed to be passed to the scaler
            $dobj = $Using:deskobj
            $desktopParams = @{
                env = $dobj.env
                scalerEnv = $dobj.scalerEnv
                desktop = $dobj.desktop
                runAsRunbook = $true
            }

            #Check to see if there is still a running job for this desktop
            $runningJobs = Get-AzAutomationJob -AutomationAccountName $Using:aaName -Name $using:rbScaler -ResourceGroupName $Using:rg -Status "Running"
            $desktopAlreadyRunningScaler = $false

            if ($runningJobs) {
                foreach ($rjob in $runningJobs) {
                    #Get the job output
                    $jobid = $rjob.JobId
                    $jobList = Get-AzAutomationJobOutput -AutomationAccountName $Using:aaName -id $jobid -ResourceGroupName $Using:rg
                    foreach ($job in $jobList) {
                        $summary = [string]$job.Summary
                        if ($summary.StartsWith('GOOD: Starting Run::')) {
                            $parts = $summary.split("::")
                            #1 = env
                            #2 = desktop
                            #3 = running environment
                            if (($desktopParams.env -eq $parts[1]) -And ($desktopParams.desktop -eq $parts[2]) -And ($desktopParams.scalerEnv -eq $parts[3])) {
                                $desktopAlreadyRunningScaler = $true
                                Write-Host "Scaler for $($desktopParams.env) / $($desktopParams.desktop) is already running - skipping"                         
                            } else {
                                Write-Host "DEBUG: Jobs show $($parts[1]) / $($parts[2]) / $($parts[3])"
                                Write-Host "DEBUG: Scaler for $($desktopParams.env) / $($desktopParams.desktop) / $($desktopParams.scalerEnv) is not running - starting run" 
                            }
                        }
                    }
                }
            } else {
                Write-Output "No currently running jobs found"
            }

            #run the scaler
            Write-Output "Scaler - Environment: $($desktopParams.env), Desktop: $($desktopParams.desktop), Running On: $($desktopParams.scalerEnv)"

            if ($desktopAlreadyRunningScaler) {
                Write-Host "Scaler for $($desktopParams.env) / $($desktopParams.desktop) is already running - skipping"                         
            } else {
                
                Write-Output "Running Runbook - $($Using:rg) / $($Using:aaName) / $($Using:rbScaler) for $($desktopParams.env), Desktop: $($desktopParams.desktop)"
                Start-AzAutomationRunbook -AutomationAccountName $Using:aaName -Name $Using:rbScaler -ResourceGroupName $Using:rg -Parameters $desktopParams -Wait
            }
        }
    }
}