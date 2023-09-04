param (
    [Parameter(Mandatory)]
    [string]$env = "dev",    
    [bool]$doLogin = $true
)

#Deploys the Proof of Concept environment which includes:
#  - log analytics
#  - keyvault (for vmss admin username and password)
#  - vnet + subnet
#  - hostpool, workspace, appgroup - key set to 30 days
#  - vmss with standard windows 10 multisession image
#  - host pool integration extension


#Resource Group
#!!!CONFIG!!!
$RG = "EHP-RG-POC-$env".toUpper()

#log into azure and change to a subscription
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

#Log into azure if doLogin is true
if ($doLogin) {
    Login-AzAccount
}



#change to the subscription
Set-AzContext -Subscription $environments.$env.subID

#create a resource group called "EHP-RG-POC"
New-AzResourceGroup -Name $RG -Location "UK South"

#deploy a bicep template
New-AzResourceGroupDeployment -ResourceGroupName $RG -TemplateFile "../BICEP/pocSetup.bicep" -Verbose -TemplateParameterObject @{ 
    "localenv" = "$env"
}
