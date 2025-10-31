<# 
//-----------------------------------------------------------------------

THE SUBJECT SCRIPT IS PROVIDED "AS IS" WITHOUT ANY WARRANTY OF ANY KIND AND SHOULD ONLY BE USED FOR TESTING OR DEMO PURPOSES.
YOU ARE FREE TO REUSE AND/OR MODIFY THE CODE TO FIT YOUR NEEDS

//-----------------------------------------------------------------------

.SYNOPSIS
Checks the ESU license status for Azure ARC servers.

.DESCRIPTION
This script validates whether ARC servers have valid ESU licenses applied by making REST API calls to Azure.
It can check individual servers or process multiple servers from a CSV file.
The script retrieves license profile information from the /machines/<machineName>/licenseProfiles/default endpoint
and provides detailed status information about ESU license assignments.

The script supports two authentication methods:
1. Service Principal authentication (requires tenantId, appID and clientSecret)
2. User token authentication (requires a valid Microsoft Entra ID authentication token)

.NOTES
File Name : CheckESUStatus.ps1
Author    : David De Backer
Version   : 1.0
Date      : 31-October-2025
Update    : 31-October-2025
Tested on : PowerShell Version 7.3.8
Module    : Azure Powershell version 9.6.0
Requires  : Powershell Core version 7.x or later
Product   : Azure ARC

.CHANGELOG
v1.0 - Initial release with support for checking ESU license status on ARC servers
       Added support for both service principal and user token authentication
       Added support for single server check and bulk CSV processing
       Added detailed status reporting and error handling

.LINK
To get more information on Azure ARC ESU license REST API please visit:
https://learn.microsoft.com/en-us/azure/azure-arc/servers/api-extended-security-updates

Reference for license profiles resource model:
https://learn.microsoft.com/en-us/azure/templates/microsoft.hybridcompute/machines/licenseprofiles

.EXAMPLE-1
./CheckESUStatus -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-clientSecret "your_application_secret_value" `
-serverResourceGroupName "rg-arcservers" `
-ARCServerName "Win2012-Server" `
-location "EastUS"

.EXAMPLE-2
$authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
./CheckESUStatus -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-serverResourceGroupName "rg-arcservers" `
-ARCServerName "Win2012-Server" `
-location "EastUS" `
-userToken $authToken

.EXAMPLE-3
./CheckESUStatus -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-clientSecret "your_application_secret_value" `
-csvFilePath "C:\Temp\ARC Servers to Check.csv" `
-location "EastUS"

These examples will check the ESU license status for ARC servers.
Example 1 shows service principal authentication for a single server.
Example 2 shows user token authentication for a single server.
Example 3 shows bulk processing from a CSV file.

For CSV processing, the file should contain the following columns:
- Name (or ARCServerName): The name of the ARC server
- ServerResourceGroupName: The resource group containing the ARC server
- (Optional) SubscriptionId: Override subscription for specific servers

#>

##############################
#Parameters definition block #
##############################

param(
    [Parameter(Mandatory=$true, HelpMessage="The ID of the subscription where the ARC servers are located.")]
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

    [Parameter(Mandatory=$false, HelpMessage="The name of the resource group where the ARC server object is stored. Required when checking a single server.")]
    [ValidatePattern('^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$', ErrorMessage="The resource group name '{0}' did not pass validation (1-90 alphanumeric characters)")]
    [Alias("srg")]
    [string]$serverResourceGroupName,

    [Parameter(Mandatory=$false, HelpMessage="The name of ARC Server object you want to check ESU license status for. Required when checking a single server.")]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$', ErrorMessage="The server name '{0}' did not pass validation (1-90 alphanumeric characters)")]
    [Alias("server")]
    [string]$ARCServerName,

    [Parameter(Mandatory=$true, HelpMessage="The region where the servers are located.")]
    [ValidateNotNullOrEmpty()]
    [Alias("l","loc")]
    [string]$location,

    [Parameter (Mandatory=$false, HelpMessage="The full path to the CSV file containing the list of ARC servers to check.")]
    [ValidateScript({
        if ($_ -and -not (Test-Path $_ -PathType Leaf)) {
            throw "The CSV file does not exist: $_"
        }
        if ($_ -and -not ($_ -match '\.csv$')) {
            throw "The file must have a .csv extension: $_"
        }
        return $true
    })]
    [Alias("csv")]
    [string] $csvFilePath,

    [Parameter(Mandatory=$false, HelpMessage="The name of the log file to be created.")]
    [Alias("log")]
    [string]$logFileName,

    [Parameter(Mandatory=$false, HelpMessage="The bearer token obtained from the Azure API by the user. If not provided, the script will require the appID, clientSecret and tenantId parameters.")]
    [Alias("token")]
    [System.Object]$userToken,

    [Parameter(Mandatory=$false, HelpMessage="Export results to a CSV file with detailed status information.")]
    [Alias("export")]
    [string]$exportCsvPath
)

#####################################
#End of Parameters definition block #
#####################################

##############################
# Variables definition block #
##############################

# Do NOT change those variables as it might break the script. They are meant to be static.
$global:creator = $MyInvocation.MyCommand.Name

# Configuration constants
$script:CONFIG = @{
    ApiVersion = "2023-06-20-preview"
    AzureResourceUrl = "https://management.azure.com/"
    LoginEndpoint = "https://login.microsoftonline.com"
    MaxRetryAttempts = 3
    RetryDelaySeconds = 5
}

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
        [string]$tenantId,
        [int]$retryCount = 3,
        [int]$retryDelaySeconds = 5
    )

    # Defines token authorization endpoint
    $oAuthEndpoint = "$($script:CONFIG.LoginEndpoint)/$tenantId/oauth2/token"

    # Builds the request body
    $authbody = @{
        grant_type = "client_credentials"
        client_id = $appID
        client_secret = $clientSecret
        resource = $script:CONFIG.AzureResourceUrl
    }
    
    # Obtains the token with retry logic
    Write-Verbose "Authenticating..."
    
    for ($attempt = 1; $attempt -le $script:CONFIG.MaxRetryAttempts; $attempt++) {
        try { 
            $response = Invoke-WebRequest -Method Post -Uri $oAuthEndpoint -ContentType "application/x-www-form-urlencoded" -Body $authbody
            $accessToken = ($response.Content | ConvertFrom-Json).access_token
            
            if ([string]::IsNullOrWhiteSpace($accessToken)) {
                throw "Authentication response did not contain a valid access token"
            }
            
            Write-Verbose "Authentication successful"
            return $accessToken
        }
        catch { 
            $errorMessage = "Authentication attempt $attempt failed: $($_.Exception.Message)"
            Write-Logfile $errorMessage "WARNING"
            
            if ($attempt -eq $script:CONFIG.MaxRetryAttempts) {
                Write-Logfile "All authentication attempts failed. Stopping." "ERROR"
                return $null
            } else {
                Write-Logfile "Retrying in $($script:CONFIG.RetryDelaySeconds) seconds..." "INFO"
                Start-Sleep -Seconds $script:CONFIG.RetryDelaySeconds
            }
        }    
    }
    
    return $null
}

function Get-ESULicenseStatus {
    param (
        [string]$subscriptionId,
        [string]$serverResourceGroupName,
        [string]$ARCServerName,
        [string]$bearerToken
    )

    try {
        # Validate required parameters
        if ([string]::IsNullOrWhiteSpace($subscriptionId)) { throw "subscriptionId is required" }
        if ([string]::IsNullOrWhiteSpace($serverResourceGroupName)) { throw "serverResourceGroupName is required" }
        if ([string]::IsNullOrWhiteSpace($ARCServerName)) { throw "ARCServerName is required" }
        if ([string]::IsNullOrWhiteSpace($bearerToken)) { throw "bearerToken is required" }

        # Build the API endpoint for license profile
        $apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$serverResourceGroupName/providers/Microsoft.HybridCompute/machines/$ARCServerName/licenseProfiles/default?api-version=$($script:CONFIG.ApiVersion)"
        
        Write-Logfile "Checking ESU license status for server '$ARCServerName' in resource group '$serverResourceGroupName'" "INFO"

        # Set headers for the request
        $headers = @{
            "Authorization" = "Bearer $bearerToken"
            "Content-Type" = "application/json"
        }

        # Make the GET request to retrieve license profile
        $response = Invoke-RestMethod -Uri $apiEndpoint -Method GET -Headers $headers

        # Parse the response to extract license information
        $licenseStatus = [PSCustomObject]@{
            ServerName = $ARCServerName
            ResourceGroup = $serverResourceGroupName
            SubscriptionId = $subscriptionId
            HasLicenseProfile = $true
            AssignedLicense = $null
            LicenseResourceId = $null
            LicenseName = $null
            LicenseResourceGroup = $null
            LicenseSubscription = $null
            Location = $response.location
            ProvisioningState = $response.properties.provisioningState
            Status = "Unknown"
            LastChecked = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            ErrorMessage = $null
        }

        # Check if ESU profile exists and has an assigned license
        if ($response.properties -and $response.properties.esuProfile) {
            if ($response.properties.esuProfile.assignedLicense) {
                $assignedLicense = $response.properties.esuProfile.assignedLicense
                $licenseStatus.AssignedLicense = $assignedLicense
                $licenseStatus.LicenseResourceId = $assignedLicense
                $licenseStatus.Status = "Licensed"
                
                # Parse license details from resource ID
                if ($assignedLicense -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.HybridCompute/licenses/([^/]+)') {
                    $licenseStatus.LicenseSubscription = $matches[1]
                    $licenseStatus.LicenseResourceGroup = $matches[2]
                    $licenseStatus.LicenseName = $matches[3]
                }
                
                Write-Logfile "Server '$ARCServerName' has ESU license assigned: $($licenseStatus.LicenseName)" "SUCCESS"
            } else {
                $licenseStatus.Status = "No License Assigned"
                Write-Logfile "Server '$ARCServerName' has no ESU license assigned" "WARNING"
            }
        } else {
            $licenseStatus.Status = "No ESU Profile"
            Write-Logfile "Server '$ARCServerName' has no ESU profile configured" "WARNING"
        }

        # Return the license status object
        return $licenseStatus

    } catch {
        $errorMessage = "Failed to check ESU license status for server '$ARCServerName': $($_.Exception.Message)"
        Write-Logfile $errorMessage "ERROR"
        
        # Handle specific HTTP status codes
        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode
            Write-Logfile "HTTP Status Code: $statusCode" "ERROR"
            
            if ($statusCode -eq 404) {
                Write-Logfile "Server '$ARCServerName' not found or no license profile exists" "ERROR"
            } elseif ($statusCode -eq 403) {
                Write-Logfile "Access denied. Check permissions for subscription and resource group" "ERROR"
            }
        }

        # Return error status object as a single PSCustomObject
        return [PSCustomObject]@{
            ServerName = $ARCServerName
            ResourceGroup = $serverResourceGroupName
            SubscriptionId = $subscriptionId
            HasLicenseProfile = $false
            AssignedLicense = $null
            LicenseResourceId = $null
            LicenseName = $null
            LicenseResourceGroup = $null
            LicenseSubscription = $null
            Location = $null
            ProvisioningState = $null
            Status = "Error"
            LastChecked = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Test-CSVRowData {
    param(
        [PSCustomObject]$row,
        [int]$rowNumber
    )
    
    $isValid = $true
    $errors = @()
    
    # Check for required fields - server name can be in 'Name' or 'ARCServerName' column
    $serverName = $null
    if ($row.PSObject.Properties['Name'] -and ![string]::IsNullOrWhiteSpace($row.Name)) {
        $serverName = $row.Name
    } elseif ($row.PSObject.Properties['ARCServerName'] -and ![string]::IsNullOrWhiteSpace($row.ARCServerName)) {
        $serverName = $row.ARCServerName
    }
    
    if ([string]::IsNullOrWhiteSpace($serverName)) {
        $errors += "Server name is required (use 'Name' or 'ARCServerName' column)"
        $isValid = $false
    }
    
    if ([string]::IsNullOrWhiteSpace($row.ServerResourceGroupName)) {
        $errors += "ServerResourceGroupName is required"
        $isValid = $false
    }
    
    # Validate subscription ID format if provided
    if ($row.PSObject.Properties['SubscriptionId'] -and 
        ![string]::IsNullOrWhiteSpace($row.SubscriptionId) -and
        $row.SubscriptionId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        $errors += "Invalid SubscriptionId format: '$($row.SubscriptionId)'"
        $isValid = $false
    }
    
    if (-not $isValid) {
        Write-Logfile "Row $rowNumber validation errors: $($errors -join '; ')" "ERROR"
    }
    
    return $isValid
}

function Write-Logfile {
    param(
        [Parameter (Mandatory=$true)]
        [Alias("m")]
        [string] $message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string] $level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$level] $message"
    
    # Output to console with appropriate colors
    switch ($level) {
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        default { Write-Host $logMessage }
    }
    
    # Also write to transcript if active
    Write-Output $logMessage
}

#######################################
# End of Function(s) definition block #
#######################################

#####################
# Main script block #
#####################

Clear-Host

# Validate parameters
if (-not $csvFilePath -and (-not $ARCServerName -or -not $serverResourceGroupName)) {
    Write-Host "Error: You must provide either a CSV file path OR both ARCServerName and serverResourceGroupName parameters." -ForegroundColor Red
    Write-Host "Use -csvFilePath for bulk processing or -ARCServerName and -serverResourceGroupName for single server check." -ForegroundColor Yellow
    exit 1
}

# Gets an authorization token either from the user provided one or from the Azure App Registration if one was provided as part of the command line.

# Check if the token is still valid
if ($userToken) {
    if ($userToken.ExpiresOn -gt (Get-Date)) {
        Write-Host "Using provided Microsoft Entra ID authentication token" -ForegroundColor Green
        #$token = $userToken.Token
        #Modified $token variable to match the new output format of the Get-AzAccessToken as it changed from a string to a SecureString type
        $token = ConvertFrom-SecureString -SecureString $userToken.Token -AsPlainText
    } else {
        Write-Host "The provided user token has expired. Please provide a valid token.`nExiting." -ForegroundColor Red
        exit 1
    }
} elseif ($tenantId -and $appID -and $clientSecret) {
    Write-Host "Getting authentication token from Microsoft Entra ID" -ForegroundColor Green
    $token = Get-AzureADBearerToken -appID $appID -clientSecret $clientSecret -tenantId $tenantId 
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Host "Failed to obtain authentication token. Exiting." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "You need to provide either the tenant, appID and clientSecrets parameters or a valid authentication token object.`nExiting." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=============================================="
Write-Host "Starting ESU License Status Check"
Write-Host "=============================================="

If (![string]::IsNullOrWhiteSpace($logFileName)) { Start-Transcript -Path $logFileName }

# Initialize results collection
$results = @()

# Process either single server or CSV file
if ($csvFilePath) {
    # Process CSV file
    try {
        $data = Import-Csv -Path $csvFilePath
        if ($data.Count -eq 0) {
            Write-Logfile "CSV file is empty or has no data rows" "ERROR"
            exit 1
        }
        Write-Logfile "$($data.Count) servers imported from CSV file" "INFO"
    } catch {
        Write-Logfile "Failed to import CSV file: $($_.Exception.Message)" "ERROR"
        exit 1
    }

    # Process each server from CSV
    $totalServers = $data.Count
    $currentServer = 0

    foreach ($row in $data) {
        $currentServer++
        $percentComplete = [math]::Round(($currentServer / $totalServers) * 100, 1)
        Write-Progress -Activity "Checking ESU License Status" -Status "Processing server $currentServer of $totalServers ($percentComplete%)" -PercentComplete $percentComplete
        
        # Validate CSV row data
        if (-not (Test-CSVRowData -row $row -rowNumber $currentServer)) {
            continue
        }
        
        # Get server name (support both 'Name' and 'ARCServerName' columns)
        $currentServerName = if (![string]::IsNullOrWhiteSpace($row.Name)) { $row.Name } else { $row.ARCServerName }
        
        # Use subscription from CSV if provided, otherwise use script parameter
        $currentSubscriptionId = if (![string]::IsNullOrWhiteSpace($row.SubscriptionId)) { $row.SubscriptionId } else { $subscriptionId }
        
        # Check ESU license status
        $result = Get-ESULicenseStatus -subscriptionId $currentSubscriptionId -serverResourceGroupName $row.ServerResourceGroupName -ARCServerName $currentServerName -bearerToken $token
        $results += , $result  # Use comma operator to ensure single object addition
    }
    
    Write-Progress -Activity "Checking ESU License Status" -Completed
    
} else {
    # Process single server
    Write-Logfile "Checking single server: $ARCServerName" "INFO"
    $result = Get-ESULicenseStatus -subscriptionId $subscriptionId -serverResourceGroupName $serverResourceGroupName -ARCServerName $ARCServerName -bearerToken $token
    $results += , $result  # Use comma operator to ensure single object addition
}

# Generate summary report
Write-Host ""
Write-Host "=============================================="
Write-Host "ESU License Status Summary"
Write-Host "=============================================="

# Debug: Show results array details
Write-Verbose "Results array count: $($results.Count)"
Write-Verbose "Results array type: $($results.GetType().Name)"

$totalServers = $results.Count
$licensedServers = ($results | Where-Object { $_.Status -eq "Licensed" }).Count
$unlicensedServers = ($results | Where-Object { $_.Status -in @("No License Assigned", "No ESU Profile") }).Count
$errorServers = ($results | Where-Object { $_.Status -eq "Error" }).Count

# Verify counts add up correctly
$calculatedTotal = $licensedServers + $unlicensedServers + $errorServers
if ($calculatedTotal -ne $totalServers) {
    Write-Logfile "Warning: Count mismatch detected. Total: $totalServers, Calculated: $calculatedTotal" "WARNING"
    Write-Logfile "Licensed: $licensedServers, Unlicensed: $unlicensedServers, Errors: $errorServers" "WARNING"
}

Write-Logfile "Total servers checked: $totalServers" "INFO"
Write-Logfile "Servers with valid ESU licenses: $licensedServers" "SUCCESS"
Write-Logfile "Servers without ESU licenses: $unlicensedServers" $(if ($unlicensedServers -gt 0) { "WARNING" } else { "INFO" })
Write-Logfile "Servers with errors: $errorServers" $(if ($errorServers -gt 0) { "ERROR" } else { "INFO" })

# Display detailed results
Write-Host ""
Write-Host "Detailed Results:"
Write-Host "================="

foreach ($result in $results) {
    $statusColor = switch ($result.Status) {
        "Licensed" { "Green" }
        "No License Assigned" { "Yellow" }
        "No ESU Profile" { "Yellow" }
        "Error" { "Red" }
        default { "White" }
    }
    
    Write-Host "Server: $($result.ServerName) | Resource Group: $($result.ResourceGroup) | Status: $($result.Status)" -ForegroundColor $statusColor
    
    if ($result.Status -eq "Licensed") {
        Write-Host "  License: $($result.LicenseName) | License RG: $($result.LicenseResourceGroup)" -ForegroundColor Gray
    }
    
    if ($result.Status -eq "Error") {
        Write-Host "  Error: $($result.ErrorMessage)" -ForegroundColor Red
    }
}

# Export results to CSV if requested
if ($exportCsvPath) {
    try {
        $results | Export-Csv -Path $exportCsvPath -NoTypeInformation
        Write-Logfile "Results exported to: $exportCsvPath" "SUCCESS"
    } catch {
        Write-Logfile "Failed to export results to CSV: $($_.Exception.Message)" "ERROR"
    }
}

If (![string]::IsNullOrWhiteSpace($logFileName)) { Stop-Transcript }

# Set exit code based on results
$exitCode = if ($errorServers -gt 0) { 1 } else { 0 }
exit $exitCode

############################
# End of Main script block #
############################