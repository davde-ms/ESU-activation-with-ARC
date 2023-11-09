<# 
//-----------------------------------------------------------------------

THE SUBJECT SCRIPT IS PROVIDED “AS IS” WITHOUT ANY WARRANTY OF ANY KIND AND SHOULD ONLY BE USED FOR TESTING OR DEMO PURPOSES.
YOU ARE FREE TO REUSE AND/OR MODIFY THE CODE TO FIT YOUR NEEDS

//-----------------------------------------------------------------------

.SYNOPSIS
Creates and manages ESU licenses to be used with Azure ARC in bulk, using an exported CSV from the Azure Portal or a manually created one.

.DESCRIPTION
This script automates the creation and management of ARC based ESU licenses for servers needing ESU activation.
It retrieves information from a CSV file and the command line for tasks like license creation, management, assignment, and removal.

.NOTES
File Name : ManageESULicenses.ps1
Author    : David De Backer
Version   : 3.0
Date      : 23-October-2023
Update    : 09-November-2023
Tested on : PowerShell Version 7.3.8
Module    : Azure Powershell version 9.6.0
Requires  : Powershell Core version 7.x or later
Product   : Azure ARC

.CHANGELOG
v1.0 - Initial release
v2.0 - Added support for license assignment and unassignment
v3.0 - Added support for ESU license exceptions (Dev/test, AVS hosted, etc.)

.LINK
To get more information on Azure ARC ESU license REST API please visit:
https://learn.microsoft.com/en-us/azure/azure-arc/servers/api-extended-security-updates

.EXAMPLE-1
./ManageESULicenses -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
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

    [Parameter(Mandatory=$true, HelpMessage="The target OS edition for the license. Valid values are Standard or Datacenter.")]
    [ValidateSet("Standard", "Datacenter",ErrorMessage="Value '{0}' is invalid. Try one of: '{1}'")]
    [Alias( "e", "ed")]
    [string]$edition,

    [Parameter (Mandatory=$true, HelpMessage="The full path to the CSV file containing the list of ESU eligible resources.")]
    [Alias("csv")]
    [string] $csvFilePath,

    [Parameter(Mandatory=$false, HelpMessage="The name of the log file to be created.")]
    [Alias("log")]
    [string]$logFileName
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

function AssignESULicense {

    param (
        [string]$appID,
        [string]$clientSecret,
        [string]$tenantId,
        [string]$licenseResourceGroupName,
        [string]$licenseName,
        [string]$ARCServerName,
        [string]$serverResourceGroupName,
        [string]$location,
        [switch]$unassign
    )

    $apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$serverResourceGroupName/providers/Microsoft.HybridCompute/machines/$ARCServerName/licenseProfiles/default`?api-version=2023-06-20-preview"
    $licenseID = "/subscriptions/$subscriptionId/resourceGroups/$licenseResourceGroupName/providers/Microsoft.HybridCompute/licenses/$licenseName" 
    $method = "PUT"

    # Gets a bearer token from the App
    $bearerToken = Get-AzureADBearerToken -appID $appID -clientSecret $clientSecret -tenantId $tenantId 

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

    # Sends the PUT request to update the license
    $response = Invoke-RestMethod -Uri $apiEndpoint -Method $method -Headers $headers -Body $requestBodyJson

    Write-Host ""
    # Sends the response to STDOUT, which would be captured by the calling script if any.
    # Feel free to comment out that line if you don't need to see the response.
    #$response
}

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
        [int]$coreCount,
        [string]$ESULicenseException
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

if ($ESULicenseException -ne $false) {$requestBody['tags']['ESU Usage'] = $ESULicenseException}

# Converts the request body to JSON
$requestBodyJson = $requestBody | ConvertTo-Json -Depth 5

# Sends the PUT request to update the license
$response = Invoke-RestMethod -Uri $apiEndpoint -Method PUT -Headers $headers -Body $requestBodyJson

# Sends the response to STDOUT, which would be captured by the calling script if any
#return $response
Write-Host "Creating or modifying $licenseName license with $coreCount $coreType"
Write-Host ""

}

function Write-Logfile  {
    param(
    [Parameter (Mandatory=$true)]
    [Alias("m")]
    [string] $message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output ("[$timestamp] " + $message)
}

#######################################
# End of Function(s) definition block #
#######################################



#####################
# Main script block #
#####################

Write-Host ""
Write-Host "==========================================="
Write-Host "Starting ESU license creation from CSV file"
Write-Host "==========================================="

If (![string]::IsNullOrWhiteSpace($logFileName)) {Start-Transcript -Path $logFileName}

$data = Import-Csv -Path $csvFilePath

foreach ($row in $data) {

    #Check if the agent version is compatible with ESU activation through ARC
    $agentVersion = [system.version]$row.agentVersion
    if ($agentVersion -lt 1.34) {
        Write-Host "Agent version is " $agentVersion "for " $row.name
        Write-Host "Minimum version required for ESU activation through ARC agent is 1.34. Skipping license creation."
        Write-Host ""
    }
    else {
        
        #Build the license name based on the prefix and suffix provided in the parameters (if any)
        $LicenseName = $licenseNamePrefix + $row.name + $licenseNameSuffix
        Write-Host "Agent version is " $agentVersion "for " $row.name ". Going for license creation."
        #Adjust coreCount and translate coreType to the right values required for the license based on the input from the CSV file
        $cores = [int]$row.cores

        #Check if the machine has been tagged for a licence exception (Dev/test, AVS hosted, etc.)
        If (![string]::IsNullOrWhiteSpace($row.ESUException)) {
            $ESUException = $row.ESUException
        }
        else {
            $ESUException = $false
        }
       
        switch ($row.isVirtual) {
            
            "Virtual" {
                Write-Host "VIRTUAL core count is " $cores "for " $row.name
                if ($cores -lt 8 -or $cores % 2 -ne 0) {
                    $row.cores = [math]::Max(8, [math]::Ceiling($cores / 2) * 2)  
                }
                $coreType = "vCore"
                CreateESULicense -subscriptionId $subscriptionId -tenantId $tenantId -appID $appID -clientSecret $clientSecret -location $location -licenseResourceGroupName $licenseResourceGroupName -licenseName $LicenseName  -state $state -edition $edition -CoreType $coreType -CoreCount $row.cores -ESULicenseException $ESUException
                ; break
            } 
            "Physical" {
                Write-Host "PHYSICAL core count is " $cores "for " $row.name
                if ($cores -lt 16 -or $cores % 2 -ne 0) {
                    $row.cores = [math]::Max(16, [math]::Ceiling($cores / 2) * 2)  
                }
                $coreType = "pCore"
                CreateESULicense -subscriptionId $subscriptionId -tenantId $tenantId -appID $appID -clientSecret $clientSecret -location $location -licenseResourceGroupName $licenseResourceGroupName -licenseName $LicenseName  -state $state -edition $edition -CoreType $coreType -CoreCount $row.cores -ESULicenseException $ESUException
                ; break
            } 
            Default {
                Write-Host "Cannot create license because of unknown machine type for $row"
            }
        }

        #Assign the license to the server if requested from the CSV file (AssignESULicense column shoud say TRUE for assignment or FALSE for unlinking)
        switch ($row.AssignESULicense) {
            "True" {
                Write-Host "Assigning ESU license ($LicenseName) to server ("$row.name")"
                
                $params = @{
                    'subscriptionId' = $subscriptionId
                    'tenantId' = $tenantId
                    'appID' = $appID
                    'clientSecret' = $clientSecret
                    'licenseResourceGroupName' = $licenseResourceGroupName
                    'licenseName' = $LicenseName
                    'serverResourceGroupName' = $row.serverResourceGroupName
                    'ARCServerName' = $row.name
                    'location' = $location
                }
                
                AssignESULicense @params
              }

            "False" {
                Write-Host "Unlinking ESU license ($LicenseName) from server ("$row.name")"

                $params = @{
                    'subscriptionId' = $subscriptionId
                    'tenantId' = $tenantId
                    'appID' = $appID
                    'clientSecret' = $clientSecret
                    'licenseResourceGroupName' = $licenseResourceGroupName
                    'licenseName' = $LicenseName
                    'serverResourceGroupName' = $row.serverResourceGroupName
                    'ARCServerName' = $row.name
                    'location' = $location
                    'unassign' = $true
                }

                AssignESULicense @params
              }

            Default {
                Write-Host "Skipping license assignment for server ("$row.name")"
                Write-Host ""
            }
        }

    }   
    
      
}


If (![string]::IsNullOrWhiteSpace($logFileName)) {Stop-Transcript}



############################
# End of Main script block #
############################