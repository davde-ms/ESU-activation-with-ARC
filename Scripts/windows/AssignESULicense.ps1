<# 
//-----------------------------------------------------------------------

THE SUBJECT SCRIPT IS PROVIDED “AS IS” WITHOUT ANY WARRANTY OF ANY KIND AND SHOULD ONLY BE USED FOR TESTING OR DEMO PURPOSES.
YOU ARE FREE TO REUSE AND/OR MODIFY THE CODE TO FIT YOUR NEEDS

//-----------------------------------------------------------------------

.SYNOPSIS
Assigns an ESU license to an ARC server object.

.DESCRIPTION
This script will assign an ARC based ESU license to an ARC server requiring ESU acvitation.
License assignment should be done with another script and so will be removal/unlinking of the license when/if required.

The script supports two authentication methods:
1. Service Principal authentication (requires tenantId, appID and clientSecret)
2. User token authentication (requires a valid Microsoft Entra ID authentication token)

.NOTES
File Name : AssignESULicense.ps1
Author    : David De Backer
Version   : 1.6
Date      : 17-October-2023
Update    : 03-September-2026
Tested on : PowerShell Version 7.6.5
Module    : Azure PowerShell Az.Accounts version 5.5.2
Requires  : Powershell Core version 7.x or later
Product   : Azure ARC

.CHANGELOG
v1.4 - Added support for user token authentication. You can now provide a Microsoft Entra ID authentication token instead of service principal credentials.
       Made tenantId, appID, and clientSecret parameters optional when using token authentication.
v1.5 - Authentication validation now returns exit code 1 for missing credentials, expired user tokens, and failed service principal token acquisition.
v1.6 - Added standard WhatIf and Confirm support and reliable nonzero exits for REST failures.
    Added focused offline tests that verify authentication failures stop before any Azure REST request.

.LINK
To get more information on Azure ARC ESU license REST API please visit:
https://learn.microsoft.com/en-us/azure/azure-arc/servers/api-extended-security-updates

.EXAMPLE-1
./Scripts/windows/AssignESULicense.ps1 -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-clientSecret "your_application_secret_value" `
-licenseResourceGroupName "rg-ARC-ESULicenses" `
-licenseName "Standard-8vcores" `
-serverResourceGroupName "rg-arservers" `
-ARCServerName "Win2012" `
-location "EastUS" 

.EXAMPLE-2
$authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
./Scripts/windows/AssignESULicense.ps1 -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-licenseResourceGroupName "rg-ARC-ESULicenses" `
-licenseName "Standard-8vcores" `
-serverResourceGroupName "rg-arservers" `
-ARCServerName "Win2012" `
-location "EastUS" `
-userToken $authToken

These examples will assign a license object named Standard-8vcores to an ARC server object named Win2012 or unlink it when using the -unassign switch.
Example 1 shows service principal authentication.
Example 2 shows how to use Microsoft Entra ID token authentication instead of service principal credentials.



#>
##############################
#Parameters definition block #
##############################

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$true, HelpMessage="The ID of the subscription where the license will be created.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid subscription ID.")]
    [Alias("sub")]
    [string]$subscriptionId,

    [Parameter(Mandatory=$false, HelpMessage="The tenant ID of the Microsoft Entra instance used for authentication.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid tenant ID.")]
    [string]$tenantId,

    [Parameter(Mandatory=$false, HelpMessage="The application (client) ID as shown under App Registrations that will be used to authenticate to the Azure API.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid application ID.")]
    [string]$appID,

    [Parameter(Mandatory=$false, HelpMessage="A valid (non expired) client secret for App Registration that will be used to authenticate to the Azure API.")]
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

    [Parameter(Mandatory=$true, HelpMessage="The name of ARC Server object you want to link to the license.")]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$', ErrorMessage="The resource group name '{0}' did not pass validation (1-90 alphanumeric characters)")]
    [Alias("server")]
    [string]$ARCServerName,

    [Parameter(Mandatory=$true, HelpMessage="The name of the resource group where the ARC server object is stored.")]
    [ValidatePattern('^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$', ErrorMessage="The resource group name '{0}' did not pass validation (1-90 alphanumeric characters)")]
    [Alias("srg")]
    [string]$serverResourceGroupName,

    [Parameter(Mandatory=$true, HelpMessage="The region where the license will be created.")]
    [ValidateNotNullOrEmpty()]
    [Alias("l","loc")]
    [string]$location,
    
    [Parameter(Mandatory=$false, HelpMessage="The bearer token obtained from the Azure API by the user. If not provided, the script will require the appID, clientSecret and tenantId parameters.")]
    [Alias("token")]
    [System.Object]$userToken,
    
    [Parameter(Mandatory=$false)]
    [Alias("u")]
    [switch]$unassign
)

#####################################
#End of Parameters definition block #
#####################################



##############################
# Variables definition block #
##############################

# Do NOT change those variables as it will break the script. They are meant to be static.
# Azure API endpoint
$apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$serverResourceGroupName/providers/Microsoft.HybridCompute/machines/$ARCServerName/licenseProfiles/default`?api-version=2023-06-20-preview"
$licenseID = "/subscriptions/$subscriptionId/resourceGroups/$licenseResourceGroupName/providers/Microsoft.HybridCompute/licenses/$licenseName" 
$method = "PUT"


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

# Gets an authorization token either from the user provided one or from the Azure App Registration if one was provided as part of the command line.

# Check if the token is still valid
if ($userToken) {
    if ($userToken.ExpiresOn -gt (Get-Date)) {
        Write-Host "Using provided Microsoft Entra ID authentication token" -ForegroundColor Green
        $bearerToken = ConvertFrom-SecureString -SecureString $userToken.Token -AsPlainText
    } else {
        Write-Host "The provided user token has expired. Please provide a valid token.`nExiting." -ForegroundColor Red
        exit 1
    }
} elseif ($tenantId -and $appID -and $clientSecret) {
    Write-Host "Getting authentication token from Microsoft Entra ID" -ForegroundColor Green
    $bearerToken = Get-AzureADBearerToken -appID $appID -clientSecret $clientSecret -tenantId $tenantId
    if ([string]::IsNullOrWhiteSpace($bearerToken)) {
        Write-Host "Failed to obtain an authentication token.`nExiting." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "You need to provide either the tenant, appID and clientSecrets parameters or a valid authentication token object.`nExiting." -ForegroundColor Red
    exit 1
}

# Sets the headers for the request
$headers = @{
    "Authorization" = "Bearer $bearerToken"
    "Content-Type" = "application/json"
}

# creates the request body depending on the action type (assign or unassign)
if ($unassign) {
    $requestBody = @{
        location = $location
        properties = @{
            esuProfile = @{
                
            }
        }
    }
} 
else {
    $requestBody = @{
        location = $location
        properties = @{
            esuProfile = @{
                "assignedLicense" = $licenseID 
            }
        }
    }  
}


# Converts the request body to JSON
$requestBodyJson = $requestBody | ConvertTo-Json -Depth 5

$action = if ($unassign) { "Unlink ESU license '$licenseName'" } else { "Assign ESU license '$licenseName'" }
if (-not $PSCmdlet.ShouldProcess($ARCServerName, $action)) {
    return
}

try {
    $response = Invoke-RestMethod -Uri $apiEndpoint -Method $method -Headers $headers -Body $requestBodyJson -ErrorAction Stop
    $response
} catch {
    Write-Host "Failed to $($action.ToLowerInvariant()) for server '$ARCServerName': $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

############################
# End of Main script block #
############################