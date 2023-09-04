# AVD Scaler

The EHP scaler provides a solution that uses Automation Accounts to schedule and action the scaling of the Ephemeral VMSS based AVD Service.  It is a STANDALONE solution capable of managed all types of AVD desktop regardless of Subscription or Resource Group.

The solution is split into two deployments - COREDEV and COREPROD.  You can deploy to either or both depending on what you want to use.

# Components

There are three main components that make up the AVD Scaler

1. Storage Tables
    - scalerschedules - provides the schedule data that can be assigned to a desktop
    - scalerdesktops - the desktops that the AVD SCaler will manage
    -scalerbankholidays - a list of bank holidays the scaler will take into account

1. Automation Account
    - Schedules - a list of schedules that define when the scaler scheduler runs
    - Runbook: AVDScalerScheduler - the runbook that is linked to the schedules and orchestrates the scaling
    - Runbook: AVDScalerParallelRun - a runbook that parallelises the scaling of the solution so it can run more than one scaler at a time
    - Runbook: AVDAutoScaler - the scaler that does the actual work (works on per env and per desktop)

1. The Deployment script - this script is used to manage all changes to the solution including:
    - changes to infrastructure (bicep)
    - updating permissions
    - updating the bank holiday table from the government gov.uk website
    - updating the runbooks
    - updating/replacing the schedules
    - forced updates to the schedule/desktop table from local config (replaces the existing content)

There is one other script to mention - EnableDisableSchedules.ps1.  This script enables or disables all the existing schedules for a particular automation runbook i.e. coredev or coreprod.  It is used when you need to disable the AVD Scheduler for a particular environment.

# The Tables

## Schedules Table

Column | Value Type | Value Example | Description
-------|------------|---------------|------------
PartitionKey | Non-Space Text | analyst | The name of the schedule
RowKey | unique integer | 1 | Not used by the scaler, but needed to ensure unique rows
CapacityMin | Integer | 10 | The minimum number of Host Pool USER SESSIONS to have running, in this example 10.
CapacityMax | Integer | 1000 | The maximum number of Host Pool USER SESSIONS permitted in this schedule
MaxInstanceScaling | Integer | 2 | The number of VMSS instances to scale up by in any one cycle
Recurrance | string | weekdays | When the schdule will recur.  Valid entries are weekdays, weekend, days of the week, e.g. monday, or nothing at all (means it runs on any day)
TimeStart | time string | 10:00 | The start time of the schedule (24h clock)
TimeEnd | time string | 18:00 | The end time of the schedule (24h clock)
Description | long text | Evening schedule | A piece of text that describes the schedule

### Typical examples

**Example**

PartitionKey = analyst
RowKey = 1
CapacityMin = 20
CapacityMax	= 1000
MaxInstanceScaling = 6
Recurrance = weekdays
TimeStart = 07:30
TimeEnd	= 10:00
Description = Morning schedule

PartitionKey = analyst
RowKey = 2
CapacityMin = 8
CapacityMax	= 1000
MaxInstanceScaling = 2
Recurrance = weekdays
TimeStart = 10:00
TimeEnd	= 18:00
Description = Day schedule


The first schedule called analyst will operate on weekdays between the hours of 07:30 and 10:00am and will provide a reserved capacity of 20 users i.e. it will always try and keep 20 user slots free, scaling upwards to ensure that this is maintained.  This is useful for "warming up" in the morning to provide lots of capacity for users to log into.

The second schedule also called analyst will operate on weekdays between the hours of 10:00 and 18:00 and will provide a reserved capacity of 4 users.  This will reduce the ongoing required spare capacity to 8 users - i.e. maintaining at least this capacity at all times on the fewest number of machines.

If a desktop allocates the schedule called "analyst", it will evaluate BOTH of the above entries.  In the event that the times overlap, it will evaluate them in "RowKey" order choosing the first one that comes back with a valid time.

You can have as many schedules assigned to the same PartitionKey (aka name) as you like.


**Example 2**

PartitionKey = fruity
RowKey = 1
CapacityMin = 20
CapacityMax	= 1000
MaxInstanceScaling = 2
Recurrance = weekdays
TimeStart = 08:00
TimeEnd	= 10:00
Description = the morning rush

PartitionKey = fruity
RowKey = 1
CapacityMin = 4
CapacityMax	= 1000
MaxInstanceScaling = 2
Recurrance = weekdays
TimeStart = 
TimeEnd	= 
Description = the 24-7 desktop

The first schedule you should now understand, but the second case has no TimeStart or TimeEnd.  That means that this is a "Fallback" schedule which can run anytime in a 24h period.  Fallback schedules are always processed AFTER timed schedules i.e. a schedule with a start and end time will always be given priority then if that does not match it *falls back* to the 24h schedule

**Example 3**

PartitionKey = flowery
RowKey = 1
CapacityMin = 20
CapacityMax	= 1000
MaxInstanceScaling = 2
Recurrance = 
TimeStart = 08:00
TimeEnd	= 10:00
Description = runs every day

in this case there is no recurrance specified.  A schedule without a recurrance will run EVERY DAY regardless.

### Special Cases

there are some Special schedules which MUST NOT have their name changed as they are in the code.  they are fairly self explanatory:

**off**

The off schedule turns the desktop off - zero instances, zero hosts.  As soon as the last user leaves the last host is removed and the VMSS scales to Zero

**manual**

The manual schedule causes the Auto Scaler to just skip the desktop and carry out no processing on it.  This is very useful if you want to take over the management of a desktop and control it yourself without interference from the scaler

**bankholiday**

This is a schedule that reads the bank holidays table, and if assigned to a desktop will scale the desktop down to the "bankholiday" settings but only do this on an approved English bank holiday.

**default**

Finally, this is the fallback of fallbacks and is the last schedule processed.  It is the schedule of last resort and is designed to keep a minimum service running if no other schedule applies.


## Desktops Table

The desktops table defines each desktop, which environment it is in, where it is located and how it is to be managed

Column | Value Type | Value Example | Description
-------|------------|---------------|------------
PartitionKey | dev:test:uat:prod | dev | the environment in with the AVD service (not the scaler) is running
RowKey | unique integer | 1 | Not used by the scaler, but needed to ensure unique rows
Desktop | non-space text | analyst | The name of the desktop
VMCapacity | integer | 4 | The number of users per virtual machine instance.  the higher the more densely packed each machine
AppliedSchedules | comma separated string | bankholiday,analyst | A comma separated string of schedules to apply
MaintenanceWindowStart | time | 05:00 | the start time for a maintenance window (currently unused)
MaintenanceWindowEnd | time | 06:00 | the end time for the maintenance window (currently unused)
VMImage | non-space text | Analyst | the image builder image that applies to the desktop (currently unused)
VMImageVersion | non-space text | latest | the version of the image to apply (currently unused)
DesktopSubID | subscription id | 11f1b987-906d-401f-a2a4-078dcacd4228 | the subscription ID where the AVD service (not scaler) is run from
DesktopRG | resource group | EHP-RG-AVD-DEV | The resource group where the AVD service (not scaler) is run from
HPName | resource name | EHP-HP-ANALYST-DEV | The name of the host pool associated with this desktop and located in DesktopRG
VMSSName | resource name | EHP-VMSS-ANALYST-DEV | The name of the VMSS associated with this desktop and located in DesktopRG
RunEnvironment | coredev:coreprod | coredev | The AVD Scaler service to use to manage the scaling of the desktop

This is fairly self explanatory, however there are three things to take note of:

1. VMCapacity - make sure that you get this figure right.  the higher it is the lower the cost (i.e. less VM instances) but the less resources users will have on their desktop.
1. RunEnvironment - make sure you select the correct AVD scaler.  At time of writing, the "coredev" scaler manages DEV and TEST WVS services, and "coreprod" manages UAT and PROD services
1. AppliedSchedules - make sure the name in the applied schedule matches exactly the name of the schedule (PartitionKey) itself.  The schedules are processed in the order they are shown.  Also make sure that the desktops on COREDEV match that on COREPROD.

AppliedSchedules example:

1. analyst - Applies all of the schedules name "analyst"
1. bankholiday,analyst - check for a bank holiday (if it is apply the bank holiday schedule), otherwise apply the analyst schedule
1. manual - set the desktop to manual control



# Configuration

Configuration of this solution requires updates in several areas:

1. DefaultScalerConfig/*.csv - update the scheduler and desktop tables
1. BICEP/azuredeploy.bicep - check the parameters and variables
1. BICEP/pocSetup.bicep - check parameters and variables - only needed if deploying the PoC
1. Scripts/DeployScaler.ps1 - see section ebtween Start and End Config tags
1. Scripts/EHPScalerScheduler.ps1 - update the environments section and tenant id
1. Scripts/EHPDoScaling.ps1 - Make sure that the $global:tenantID is correctly set
1. Scripts/DeployPoC.ps1 - update environments section if using the PoC

All values that are needed can be search for using something file VS Code file search and look for !!!CONFIG!!! and \<change me\>

# PoC Setup

The PoC is a simple non-domain joined host pool configuration driven by a VMSS.  It will deploy all the required components to a dedicated Resource Group.  To deploy the environment, update the pocSetup.bicep and DeployPoC.ps1 files to match your environment then run:

```powershell
Scripts/DeployPoc.ps1 -env [dev or prod] -doLogin [true or false]
```

- ***env*** denotes the environment you wish to deploy, defaults to dev and as such uses the DEV environment you have configured when modifying the DeployPoc.ps1 / pocSetup.bicep files

- ***doLogin*** if set up tru, will pop up an interactive screen to acquire your login details.

By default the POC will deploy with a single VM active in the VMSS - make sure to scale the VMSS to zero if this is not yet wanted to conserve cost.

## Notes about the PoC environment

- As this is only a PoC you will have 30 days before the Host Pool token expires.  After this time you will need to generate a new HP token AND re-deploy the token extension for the VMSS.

- because this is a PoC it does not connect to or deploy an AD/AADDS service which means that hosts in the host pool will show up as unhealthy - this is normal.

- to stop the scaler to ignore unhealthy hosts (normally it would remove them), in the EHPDoScaling.ps1 script, change the global variable ***scaleTestMode*** to be true.  Doing this stops unhealthy hosts being deleted from the host pool and produces a warning in the logs instead.

- to try out the scaling without the scheduled scaler kicking in, use the EnableDisableSchedules.ps1 to disable the schedules, then open the EHPAutoScaler runbook in the automation account and run it in test mode.  To run against the DEV POC environment use these parameters:

- ENV: dev
- SCALERENV: ehpdev
- DESKTOP: poc
- DOLOGIN: $false
- DRYRUN: $false
- RUNASRUNBOOK: $true


# The Deployment Script

The deployment script (/AVD/ScalerInfrastructure/Scripts/DeployScaler.ps1) is a comprehensive management script for the AVD scaler that does the following:

***NOTE: You will be required to grant permissions to the Graph API for the deployment***

- changes to (or new deployments of) infrastructure (bicep)
- updating permissions (including creating a group)
- updating the bank holiday table from the government gov.uk website
- updating the runbooks
- updating/replacing the schedules
- forced updates to the schedule/desktop table from local config (replaces the existing content)
- adding a new desktop

This script should be your first port of call for ALL changes to the service.  The script itself is well documented and describes everything you need however here are a few examples:

**Example 1 - Update the bank holiday table with live data from gov.uk**
```powershell
.\DeployScaler.ps1 -env dev -dryRun $false -doLogin $false -updateBankHoliday $true
```

**Example 2 - Update the scheduler and desktop tables from the CSV files**

```powershell
.\DeployScaler.ps1 -env dev -dryRun $false -doLogin $false -forceTableUpdate $true
```

**Example 3 - Update the Automation Runbooks AND run schedules**

```powershell
.\DeployScaler.ps1 -env dev -dryRun $false -doLogin $false -updateRunBook $true
```

NOTE: This will create a runbook and copy the content of the scripts to the runbook, then publish them.  It will then also define and link the schedules to the AVDScalerScheduler 
runbook.  By default schedules are set to active

**Example 4 - Update only the schedules but also set them to disabled**

```powershell
.\DeployScaler.ps1 -env dev -dryRun $false -doLogin $false -updateSchedules $true -schedulesEnabled $false
```

Look in the scaler script at the "scheduleInterval" config parameter - this defines the number of schedules and their placement.  Do not set an interval of less than 5 mins.

**Example 5 - Update the permissions on resources to allow the scaler to function**
```

```powershell
.\DeployScaler.ps1 -env dev -dryRun $false -doLogin $false -assignRoles $true
```

**Example 6 - Do a new deployment on prod and log in but don't enable the schedules**

```powershell
.\DeployScaler.ps1 -env prod -dryRun $false -newBuild $true -schedulesEnabled $false
```

# Enable/Disable schedules

There is a script called "EnableDisableSchedules.ps1".  this script enables or disables the schedules (does not do anything else) in the automation account specified.  It runs like this:

```powershell
./EnableDisableSchedules.ps1 -runEnvironment [coredev|coreprod] -schedulesEnabled [$true|$false] -doLogin [$true|$false]
```

# Schedule Workflow

1. Scaler runs against a specific desktop in a specific AVD environment (dev,test,uat.prod) and against the appropriate Scaler (coredev or coreprod)
1. It grabs the details about the desktops, schedules, the VMSS, Host Pool and Host Pool Hosts
1. From this it determines the current state and which schedule to run
1. From the desktop information and schedule information coupled with the current number of instances and users it works out the desired state
1. It then initiates the desired state.

Things to note:

1. When scaling it or down, the scaler is limited by MaxInstanceScaling in the scheduler table that only allows the system to scale by this number of machines at any one time
1. when scaling (up or down), the system will no make any changes until that operation has completed
1. When scaling down, it determines the host pool hosts to put into drain mode by the number of users on them with hosts having zero users being put into drain mode first
1. After putting host pool hosts into drain mode it will not turn them off until ALL users are off the host
1. Once at zero users a host pool host in drain mode will be removed from the host pool then the VMSS
1. Host pool hosts that are orphened (not vmss instance under it) will be cleaned up and removed automatically
1. The same applies when there is a vmss instance without a host pool host associated.
1. The VMSS will not scale up any more than MaxInstanceScaling above the numebr of host pool hosts to prevent runaway scaling
1. The VMSS will also not scale up if it reaches the capacity max limit (specified in the schedule)

# Required for Formal Implementation

In order to get the solution up and running on the PROD services do the following:

1. Disable the logic apps that are running
1. Run the EnableDisableSchedules.ps1 script to enable the existing schedules

Then, once it has been tested you need to do the following:

1. Permanently disable the logic apps by disabling them in the Pipelines and ARM templates
1. Update the key rotation script to disable/enable the automation schedules rather than the logic app


# Future

The solution has been designed to be as flexible as possible.  It should be well documented throughout and can be easily extended.  suggestions include:

1. Integrate the key change and make use of the maintenance windows
1. Stop VMSS doing rolling updates and get the script to do those updates in the maintenance window instead
1. Get the solution to auto build a new desktop based on the parameters in the desktop table - desktops on demand.