<# 
//-----------------------------------------------------------------------

THE SUBJECT SCRIPT IS PROVIDED “AS IS” WITHOUT ANY WARRANTY OF ANY KIND AND SHOULD ONLY BE USED FOR TESTING OR DEMO PURPOSES.
YOU ARE FREE TO REUSE AND/OR MODIFY THE CODE TO FIT YOUR NEEDS

//-----------------------------------------------------------------------

.SYNOPSIS
Creates (or updates) an ESU license to be used with Azure ARC.

.DESCRIPTION
This script creates or modifies an Azure Arc enabled ESU license that can later be assigned to an eligible server.
License assignment and unlinking are performed by the assignment scripts.

The exact target values are Windows Server 2012, Windows Server 2012 R2, and Windows Server 2016.
When -target is omitted, the default is Windows Server 2012.

The Connected Machine agent requirement is version 1.34 or later for Windows Server 2012 and Windows Server 2012 R2, and version 1.62 or later for Windows Server 2016. This single-license script does not inspect a machine or validate its agent version.

This script does not accept Volume Licensing transition fields. Windows Server 2016 does not support Volume Licensing transition data. For bulk input, the WS2012 reserved exception values WS2012 VISUAL STUDIO DEV TEST, WS2012 DISASTER RECOVERY, and WS2012 MULTIPURPOSE are incompatible with a Windows Server 2016 target; tags do not establish eligibility or alter billing.

The script supports two authentication methods:
1. Service principal authentication with -tenantId, -appID, and -clientSecret.
2. A valid Get-AzAccessToken token object supplied with -userToken (alias -token).

-WhatIf authenticates, describes the target-specific create or modify operation, and sends no license mutation request. Declining -Confirm also sends no mutation request.

.NOTES
File Name : CreateESULicense.ps1
Author    : David De Backer
Version   : 2.4
Date      : 09-October-2023
Update    : 03-September-2026
Tested on : PowerShell Version 7.6.5
Module    : Azure PowerShell Az.Accounts version 5.5.2
Requires  : Powershell Core version 7.x or later
Product   : Azure ARC

.CHANGELOG
v2.1 - Added support for user token authentication. You can now provide a Microsoft Entra ID authentication token instead of service principal credentials.
       Made tenantId, appID, and clientSecret parameters optional when using token authentication.
v2.2 - Authentication validation now returns exit code 1 for missing credentials, expired user tokens, and failed service principal token acquisition.
v2.3 - Added standard WhatIf and Confirm support and reliable nonzero exits for REST failures.
    Added focused offline tests that verify authentication failures stop before any Azure REST request.
v2.4 - Added Windows Server 2012 R2 and Windows Server 2016 license targets.
    Updated license create and modify requests to API version 2026-06-16-preview.

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

.EXAMPLE-2
$authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
./CreateESULicense -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-licenseResourceGroupName "rg-arclicenses" `
-licenseName "Standard-8vcores" `
-location "EastUS" `
-state "Deactivated" `
-edition "Standard" `
-coreType "vCore" `
-coreCount 8 `
-target "Windows Server 2012 R2" `
-userToken $authToken

.EXAMPLE-3
./CreateESULicense -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-clientSecret "your_application_secret_value" `
-licenseResourceGroupName "rg-arclicenses" `
-licenseName "Standard-16vcores-WS2016" `
-location "EastUS" `
-state "Deactivated" `
-edition "Standard" `
-coreType "vCore" `
-coreCount 16 `
-target "Windows Server 2016"

Example 1 uses service principal authentication and omits target, so it creates a Windows Server 2012 license by default.
Example 2 uses Microsoft Entra ID token authentication and explicitly creates a Windows Server 2012 R2 license.
Example 3 uses service principal authentication and explicitly creates a Windows Server 2016 license.

Add -WhatIf to any example to authenticate and preview the operation without sending the create or modify request.

To modify an existing license object, use the same script while providing different values.
Note that you can only change the NUMBER of cores associated to a license as well as the ACTIVATION state.
You CAN NEITHER modify the EDITION nor can you modify the TYPE of the cores configured for the license.

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

    [Parameter(Mandatory=$false, HelpMessage="The Windows Server version targeted by the license. Defaults to Windows Server 2012.")]
    [ValidateSet("Windows Server 2012", "Windows Server 2012 R2", "Windows Server 2016", ErrorMessage="Value '{0}' is invalid. Try one of: '{1}'")]
    [string]$target = "Windows Server 2012",

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
    [int] $coreCount,

    [Parameter(Mandatory=$false, HelpMessage="The bearer token obtained from the Azure API by the user. If not provided, the script will require the appID, clientSecret and tenantId parameters.")]
    [Alias("token")]
    [System.Object]$userToken
)

#####################################
#End of Parameters definition block #
#####################################



##############################
# Variables definition block #
##############################

# Do NOT change those variables as it will break the script. They are meant to be static.
$licenseApiVersion = "2026-06-16-preview"
$apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$licenseResourceGroupName/providers/Microsoft.HybridCompute/licenses/$licenseName`?api-version=$licenseApiVersion"
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

# Defines the request body as a PowerShell hashtable
$requestBody = @{
    location = $location
    properties = @{
        licenseDetails = @{
            state = $state
            target = $target
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
Write-Verbose "License request payload for target '$target': $requestBodyJson"

if (-not $PSCmdlet.ShouldProcess($licenseName, "Create or modify $target $edition ESU license with $coreCount $coreType")) {
    return
}

try {
    $response = Invoke-RestMethod -Uri $apiEndpoint -Method $method -Headers $headers -Body $requestBodyJson -ErrorAction Stop
    $response
} catch {
    Write-Host "Failed to create or modify ESU license '$licenseName': $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

############################
# End of Main script block #
############################