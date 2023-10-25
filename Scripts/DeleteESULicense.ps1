<# 
//-----------------------------------------------------------------------

THE SUBJECT SCRIPT IS PROVIDED “AS IS” WITHOUT ANY WARRANTY OF ANY KIND AND SHOULD ONLY BE USED FOR TESTING OR DEMO PURPOSES.
YOU ARE FREE TO REUSE AND/OR MODIFY THE CODE TO FIT YOUR NEEDS

//-----------------------------------------------------------------------

.SYNOPSIS
Deletes an ESU license used in Azure ARC.

.DESCRIPTION
This script will delete an existing ARC based ESU license.
License deletion should only be done when it is not required anymore and cannot be reused for another ARC server.
Deleting a license will sever the association between that license and the ARC server object previously linked to it.
Deleting a license will stop the monthly billing for the ESU associated with that license.

.NOTES
File Name : DeleteESULicense.ps1
Author    : David De Backer
Version   : 1.0
Date      : 19-October-2023
Update    : 22-October-2023
Tested on : PowerShell Version 7.3.8
Module    : Azure Powershell version 9.6.0
Requires  : Powershell Core version 7.x or later
Product   : Azure ARC

.LINK
To get more information on Azure ARC ESU license REST API please visit:
https://learn.microsoft.com/en-us/azure/azure-arc/servers/api-extended-security-updates

.EXAMPLE-1
./DeleteESULicense -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-clientSecret "your_application_secret_value" `
-licenseResourceGroupName "rg-ARC-ESULicenses" `
-licenseName "Standard-8vcores"

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
    [string]$subscriptionId,

    [Parameter(Mandatory=$true, HelpMessage="The tenant ID of the Microsoft Entra instance used for authentication.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid tenant ID.")]
    [string]$tenantId,

    [Parameter(Mandatory=$true, HelpMessage="The application (client) ID as shown under App Registrations that will be used to authenticate to the Azure API.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid application ID.")]
    [string]$appID,

    [Parameter(Mandatory=$true, HelpMessage="A valid (non expired) client secret for App Registration that will be used to authenticate to the Azure API.")]
    [Alias("secret","s")]
    [string]$clientSecret,

    [Parameter(Mandatory=$true, HelpMessage="The name of the resource group where the license will be created.")]
    [ValidatePattern('^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$', ErrorMessage="The resource group name '{0}' did not pass validation (1-90 alphanumeric characters)")]
    [Alias("lrg")]
    [string]$licenseResourceGroupName,

    [Parameter(Mandatory=$true, HelpMessage="The name of the ESU license to be created.")]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$', ErrorMessage="The resource group name '{0}' did not pass validation (1-90 alphanumeric characters)")]
    [Alias("ln","lic","license")]
    [string]$licenseName
)

#####################################
#End of Parameters definition block #
#####################################



##############################
# Variables definition block #
##############################

# Do NOT change those variables as it will break the script. They are meant to be static.
# Azure API endpoint
$apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$licenseResourceGroupName/providers/Microsoft.HybridCompute/licenses/$licenseName`?api-version=2023-06-20-preview"
$method = "DELETE"

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

# Sends the PUT request to update the license
$response = Invoke-RestMethod -Uri $apiEndpoint -Method $method -Headers $headers

# Sends the response to STDOUT, which would be captured by the calling script if any
$response

############################
# End of Main script block #
############################