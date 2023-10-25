<# 
//-----------------------------------------------------------------------

THE SUBJECT SCRIPT IS PROVIDED “AS IS” WITHOUT ANY WARRANTY OF ANY KIND AND SHOULD ONLY BE USED FOR TESTING OR DEMO PURPOSES.
YOU ARE FREE TO REUSE AND/OR MODIFY THE CODE TO FIT YOUR NEEDS

//-----------------------------------------------------------------------

.SYNOPSIS
Creates (or updates) an ESU license to be used with Azure ARC.

.DESCRIPTION
This script will create (or modify) an ARC based ESU license that can later be assigned to your servers requiring ESU acvitation.
License assignment should be done with another script and so will be removal/unlinking of the license when/if required.

.NOTES
File Name : CreateESULicense.ps1
Author    : David De Backer
Version   : 2.0
Date      : 09-October-2023
Update    : 25-October-2023
Tested on : PowerShell Version 7.3.8
Module    : Azure Powershell version 9.6.0
Requires  : Powershell Core version 7.x or later
Product   : Azure ARC

.LINK
To get more information on Azure ARC ESU license REST API please visit:
https://learn.microsoft.com/en-us/azure/azure-arc/servers/api-extended-security-updates

.EXAMPLE-1
./CreateESULicense -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-clientSecret "your_application_secret_value" `
-licenseResourceGroupName "rg-arclicenses" `
-licenseName "Standard-8vcores" `
-location "EastUS" `
-state "Deactivated" `
-edition "Standard" `
-coreType "vCore" `
-coreCount 8 

This example will create a license object that is Deactivated with a virtual cores count of 8 and of type Standard

To modify an existing license object, use the same script while providing different values.
Note that you can only change the NUMBER of cores associated to a license as well as the ACTIVATION state.
You CAN NEITHER modify the EDITION nor can you modify the TYPE of the cores configured for the license.

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

    [Parameter(Mandatory=$true, HelpMessage="The name of the ESU license to be created.")]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$', ErrorMessage="The resource group name '{0}' did not pass validation (1-90 alphanumeric characters)")]
    [Alias("ln","lic","license")]
    [string]$licenseName,

    [Parameter(Mandatory=$true, HelpMessage="The region where the license will be created.")]
    [ValidateNotNullOrEmpty()]
    [Alias("l")]
    [string]$location,

    [Parameter(Mandatory=$true, HelpMessage="The activated state of the license. Valid values are Activated or Deactivated.")]
    [ValidateSet("Activated", "Deactivated",ErrorMessage="Value '{0}' is invalid. Try one of: '{1}'")]
    [string]$state,

    [Parameter(Mandatory=$true, HelpMessage="The target OS edition for the license. Valid values are Standard or Datacenter.")]
    [ValidateSet("Standard", "Datacenter",ErrorMessage="Value '{0}' is invalid. Try one of: '{1}'")]
    [Alias( "e", "ed")]
    [string]$edition,

    [Parameter (Mandatory, HelpMessage="The type of license. Valid values are pCore for physical cores or vCore for virtual cores.")]
    [ValidateSet ("pCore", "vCore",ErrorMessage="Value '{0}' is invalid. Try one of: '{1}'")]
    [Alias("t")]
    [string] $coreType,

    [Parameter (Mandatory, HelpMessage="The number of cores to be licensed. Valid values are 16-256 for pCore and 8-128 for vCore.")]
    # The MAX values can be changed in the param validation block below if you need to license more cores (unlikely)
    # Those values have been set as a precaution to avoid accidental licensing of too many cores
    # The minimum value shoud stay as is.
    # Changing the minimum number of cores ($min value herebelow) would have be in violation of with the Microsoft Licensing Terms

    [ValidateScript ({
        switch ($coreType) {
            "pCore" { $min = 16; $max = 256 }
            "vCore" { $min = 8; $max = 128 }
        }
        $_ -ge $min -and $_ -le $max -and $_ % 2 -eq 0
    }, ErrorMessage = "The item '{0}' did not pass validation of statements '{1}'")]
    [Alias("cc","count")]
    [int] $coreCount
)

#####################################
#End of Parameters definition block #
#####################################



##############################
# Variables definition block #
##############################

# Do NOT change those variables as it will break the script. They are meant to be static.
$targetOS = "Windows Server 2012"
# Azure API endpoint
$apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$licenseResourceGroupName/providers/Microsoft.HybridCompute/licenses/$licenseName`?api-version=2023-06-20-preview"
$method = "PUT"
$creator = $MyInvocation.MyCommand.Name

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

#######################################
# End of Function(s) definition block #
#######################################



#####################
# Main script block #
#####################

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
            target = $targetOS
            edition = $edition
            Type = $coreType
            Processors = $coreCount
        }
    }
    tags = @{
        CreatedBy = "$creator"
    }
}

# Converts the request body to JSON
$requestBodyJson = $requestBody | ConvertTo-Json -Depth 5

# Sends the PUT request to update the license
$response = Invoke-RestMethod -Uri $apiEndpoint -Method $method -Headers $headers -Body $requestBodyJson

# Sends the response to STDOUT, which would be captured by the calling script if any
$response

############################
# End of Main script block #
############################