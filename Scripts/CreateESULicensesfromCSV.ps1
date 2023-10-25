<# 
//-----------------------------------------------------------------------

THE SUBJECT SCRIPT IS PROVIDED “AS IS” WITHOUT ANY WARRANTY OF ANY KIND AND SHOULD ONLY BE USED FOR TESTING OR DEMO PURPOSES.
YOU ARE FREE TO REUSE AND/OR MODIFY THE CODE TO FIT YOUR NEEDS

//-----------------------------------------------------------------------

.SYNOPSIS
Creates ESU licenses to be used with Azure ARC in bulk, using a exported CSV from the Azure Portal.

.DESCRIPTION
This script will create ARC based ESU licenses that can later be assigned to your servers requiring ESU acvitation.
Creation will fetch parameters information from a CSV file coming from an Azure Portal export of the ARC ESU Eligible resources.
License assignment should be done with another script and so will be removal/unlinking of the license when/if required.

.NOTES
File Name : CreateESUfromCSV.ps1
Author    : David De Backer
Version   : 1.5
Date      : 23-October-2023
Update    : 25-October-2023
Tested on : PowerShell Version 7.3.8
Module    : Azure Powershell version 9.6.0
Requires  : Powershell Core version 7.x or later
Product   : Azure ARC

.LINK
To get more information on Azure ARC ESU license REST API please visit:
https://learn.microsoft.com/en-us/azure/azure-arc/servers/api-extended-security-updates

.EXAMPLE-1
./CreateESULicensesfromCSV -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-clientSecret "your_application_secret_value" `
-licenseResourceGroupName "rg-ARC-ESULicenses" `
-location "EastUS" `
-state "Deactivated" `
-edition "Standard" `
-csvFilePath "C:\Temp\ESU Eligible Resources.csv" `
-licenseNamePrefix "ESU-" `
-licenseNameSuffix "-2023"

This example will create ESU license objects based on the input from the C:\Temp\ESU Eligible Resources.csv file contents.
The licenses will be using Standard edition type, be deactivated and their core count as well as core type will be based on the input from the CSV file.
The license name will be prefixed with ESU- , will contain the servername (coming from the CSV) and be suffixed with -2023.
As in the example, the license name will be ESU-ServerName-2023.

You can activate the license by changing the -state parameter to 'Activated' and run the same script with the same values again.
You CANNOT edit the contents of the CSV file to edit values as it will result in an error when trying to create the license.

#>

##############################
#Parameters definition block #
##############################

param(
    [Parameter(Mandatory=$true, HelpMessage="The ID of the subscription where the license will be created.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid subscription ID.")]
    [Alias("sub")]
    [string]$subscriptionId,

    [Parameter(Mandatory=$true, HelpMessage="The tenant ID of the Microsoft Entra instance used for authentication.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid tenant ID.")]
    [string]$tenantId,

    [Parameter(Mandatory=$true, HelpMessage="The application (client) ID as shown under App Registrations that will be used to authenticate to the Azure API.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid application ID.")]
    [string]$appID,

    [Parameter(Mandatory=$true, HelpMessage="A valid (non expired) client secret for App Registration that will be used to authenticate to the Azure API.")]
    [Alias("s","secret","sec")]
    [string]$clientSecret,

    [Parameter(Mandatory=$true, HelpMessage="The name of the resource group where the license will be created.")]
    [ValidatePattern('^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$', ErrorMessage="The resource group name '{0}' did not pass validation (1-90 alphanumeric characters)")]
    [Alias("lrg")]
    [string]$licenseResourceGroupName,

    [Parameter(Mandatory=$false, HelpMessage="The name of the ESU license to be created.")]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,20}$', ErrorMessage="The resource group name '{0}' did not pass validation (1-90 alphanumeric characters)")]
    [Alias("lp")]
    [string]$licenseNamePrefix,

    [Parameter(Mandatory=$false, HelpMessage="The name of the ESU license to be created.")]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,20}$', ErrorMessage="The resource group name '{0}' did not pass validation (1-90 alphanumeric characters)")]
    [Alias("ls")]
    [string]$licenseNameSuffix,

    [Parameter(Mandatory=$true, HelpMessage="The region where the license will be created.")]
    [ValidateNotNullOrEmpty()]
    [Alias("l")]
    [string]$location,

    [Parameter(Mandatory=$true, HelpMessage="The activated state of the license. Valid values are Activated or Deactivated.")]
    [ValidateSet("Activated", "Deactivated",ErrorMessage="Value '{0}' is invalid. Try one of: '{1}'")]
    [string]$state,

    [Parameter(Mandatory=$false, HelpMessage="The target OS edition for the license. Valid values are Standard or Datacenter.")]
    [ValidateSet("Standard", "Datacenter",ErrorMessage="Value '{0}' is invalid. Try one of: '{1}'")]
    [Alias( "e", "ed")]
    [string]$edition,

    [Parameter (Mandatory=$false, HelpMessage="The type of license. Valid values are pCore for physical cores or vCore for virtual cores.")]
    [Alias("f","csv")]
    [string] $csvFilePath
)

#####################################
#End of Parameters definition block #
#####################################



##############################
# Variables definition block #
##############################

# Do NOT change those variables as it might break the script. They are meant to be static.
$global:targetOS = "Windows Server 2012"
$global:creator = $MyInvocation.MyCommand.Name


#########################################
# End of the variables definition block #
#########################################



################################
# Function(s) definition block #
################################

function Get-AzureADBearerToken {
    param(
        [string]$appID,
        [string]$clientSecret,
        [string]$tenantId
    )

    # Defines token authorization endpoint
    $oAuthEndpoint = "https://login.microsoftonline.com/$tenantId/oauth2/token"

    # Builds the request body
    $authbody = @{
        grant_type = "client_credentials"
        client_id = $appID
        client_secret = $clientSecret
        resource = "https://management.azure.com/"
    }
    
    # Obtains the token
    Write-Verbose "Authenticating..."
    try { 
            $response = Invoke-WebRequest -Method Post -Uri $oAuthEndpoint -ContentType "application/x-www-form-urlencoded" -Body $authbody
            $accessToken = ($response.Content | ConvertFrom-Json).access_token
            return $accessToken
    }
    
    catch { 
        Write-Error "Error obtaining Bearer token: $_"
        return $null
     }    
}

function CreateESULicense {
    param (
        [string]$appID,
        [string]$clientSecret,
        [string]$tenantId,
        [string]$location,
        [string]$licenseResourceGroupName,
        [string]$licenseName,
        [string]$state,
        [string]$edition,
        [string]$coreType,
        [int]$coreCount
    )
    
$apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$licenseResourceGroupName/providers/Microsoft.HybridCompute/licenses/$licenseName`?api-version=2023-06-20-preview"

# Gets a bearer token from the App
$bearerToken = Get-AzureADBearerToken -appID $appID -clientSecret $clientSecret -tenantId $tenantId 

# Sets the headers for the request
$headers = @{
    "Authorization" = "Bearer $bearerToken"
    "Content-Type" = "application/json"
}

# Defines the request body as a PowerShell hashtable
$requestBody = @{
    location = $location
    properties = @{
        licenseDetails = @{
            state = $state
            target = $global:targetOS
            edition = $edition
            Type = $coreType
            Processors = $coreCount
        }
    }
    tags = @{
        CreatedBy = "$global:creator"
    }
}

# Converts the request body to JSON
$requestBodyJson = $requestBody | ConvertTo-Json -Depth 5

# Sends the PUT request to update the license
$response = Invoke-RestMethod -Uri $apiEndpoint -Method PUT -Headers $headers -Body $requestBodyJson

# Sends the response to STDOUT, which would be captured by the calling script if any
return $response

}

#######################################
# End of Function(s) definition block #
#######################################



#####################
# Main script block #
#####################

# Invoke your second script here using the provided arguments
    # For example:
    # & "Path\To\Your\SecondScript.ps1" -ServerName $ServerName -LicenseEdition $LicenseEdition -CoreType $CoreType -CoreCount $CoreCount

$data = Import-Csv -Path $csvFilePath

foreach ($row in $data) {

    #Build the license name based on the prefix and suffix provided in the parameters (if any)
    $LicenseName = $licenseNamePrefix + $row.name + $licenseNameSuffix
    
    #Adjust coreCount and translate coreType to the right values required for the license based on the input from the CSV file
    switch ($row.isVirtual) {
        1 {
            if ($row.cores -lt 8 -or $row.cores % 2 -ne 0) {
                $row.cores = [math]::Max(8, [math]::Ceiling($row.cores / 2) * 2)
            }
            $row.model = "vCore"
            CreateESULicense -subscriptionId $subscriptionId -tenantId $tenantId -appID $appID -clientSecret $clientSecret -location $location -licenseResourceGroupName $licenseResourceGroupName -licenseName $LicenseName  -state $state -edition $edition -CoreType $row.model -CoreCount $row.cores
        }
        0 {
            if ($row.cores -lt 16 -or $row.cores % 2 -ne 0) {
                $row.cores = [math]::Max(16, [math]::Ceiling($row.cores / 2) * 2)
            }
            $row.model = "pCore"
            CreateESULicense -subscriptionId $subscriptionId -tenantId $tenantId -appID $appID -clientSecret $clientSecret -location $location -licenseResourceGroupName $licenseResourceGroupName -licenseName $LicenseName  -state $state -edition $edition -CoreType $row.model -CoreCount $row.cores
        }
        Default {
            Write-Host "Cannot create license because of unknown machine type for $row"
        }
    }
      
}






############################
# End of Main script block #
############################