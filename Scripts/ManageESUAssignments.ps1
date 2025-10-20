<# 
//-----------------------------------------------------------------------

THE SUBJECT SCRIPT IS PROVIDED “AS IS” WITHOUT ANY WARRANTY OF ANY KIND AND SHOULD ONLY BE USED FOR TESTING OR DEMO PURPOSES.
YOU ARE FREE TO REUSE AND/OR MODIFY THE CODE TO FIT YOUR NEEDS

//-----------------------------------------------------------------------

.SYNOPSIS
Manages ESU licenses assignments in bulk, taking its inputs from a CSV file.

.DESCRIPTION
This script manages the assignment of ARC based ESU licenses for servers needing ESU activation.
It retrieves information from a CSV file and the command line for tasks like license assignment and removal.
Its purpose is to allow you to assign a single license to multiple servers at once or to remove a license from multiple servers at once.
It supports cross-subscription scenarios where ESU licenses can be located in different subscriptions than the ARC servers.
Its main targets are servers that are exempted from ESU costs like VMs on Azure VMware Services or servers that are described in tne following article:
https://learn.microsoft.com/en-us/azure/azure-arc/servers/deliver-extended-security-updates#additional-scenarios

The script supports two authentication methods:
1. Service Principal authentication (requires tenantId, appID, and clientSecret)
2. User token authentication (requires a valid Microsoft Entra ID authentication token)

.NOTES
File Name : ManageESUAssignments.ps1
Author    : David De Backer
Version   : 1.3
Date      : 10-October-2025  
Update    : 20-October-2025
Tested on : PowerShell Version 7.3.8
Module    : Azure Powershell version 9.6.0
Requires  : Powershell Core version 7.x or later
Product   : Azure ARC

.CHANGELOG
v1.0 - Initial release
v1.1 - Added support for cross-subscription license assignments. ESU licenses can now be located in different subscriptions than ARC servers.
       Added backward compatibility with existing CSV format.
       Added optional -licenseSubscriptionId parameter and LicenseSubscriptionId CSV column.
       CSV LicenseSubscriptionId column always takes precedence over command line parameter when provided.
v1.2 - Added support for user token authentication. You can now provide a Microsoft Entra ID authentication token instead of service principal credentials.
       Made tenantId, appID, and clientSecret parameters optional when using token authentication.
v1.3 - Major optimization and reliability improvements:
       • Enhanced error handling with detailed logging and severity levels (INFO, WARNING, ERROR, SUCCESS)
       • Added comprehensive input validation for CSV files and data integrity checks
       • Implemented progress tracking with real-time progress bar and operation counters
       • Added dry-run mode (-DryRun parameter) for testing without making actual changes
       • Enhanced authentication with retry logic and better token validation
       • Added Test-CSVRowData function for validating each CSV row before processing
       • Improved Write-Logfile function with color-coded console output
       • Added configuration constants for easier maintenance and API version management
       • Implemented proper exit codes (0 for success, 1 for errors) for automation scenarios
       • Added detailed summary report with success/failure/skipped operation counts
       • Enhanced parameter validation with better error messages and file existence checks
       • Improved API error response capture for better debugging
       • Added graceful error recovery to continue processing on individual row failures


.LINK
To get more information on Azure ARC ESU license REST API please visit:
https://learn.microsoft.com/en-us/azure/azure-arc/servers/api-extended-security-updates

.EXAMPLE-1
./ManageESUAssignments -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-clientSecret "your_application_secret_value" `
-location "EastUS" `
-csvFilePath "C:\Temp\ESU Association File.csv"

.EXAMPLE-2
./ManageESUAssignments -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-licenseSubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" `
-tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-clientSecret "your_application_secret_value" `
-location "EastUS" `
-csvFilePath "C:\Temp\ESU Association File.csv"

.EXAMPLE-3
$authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
./ManageESUAssignments -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-location "EastUS" `
-csvFilePath "C:\Temp\ESU Association File.csv" `
-userToken $authToken

.EXAMPLE-4
./ManageESUAssignments -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-clientSecret "your_application_secret_value" `
-location "EastUS" `
-csvFilePath "C:\Temp\ESU Association File.csv" `
-DryRun

These examples will assign or unassign (unlink) ESU licenses to/from ARC server objects based on the information provided in the CSV file.
Example 2 shows how to specify a different subscription for ESU licenses.
Example 3 shows how to use Microsoft Entra ID token authentication instead of service principal credentials.
Example 4 shows how to perform a dry run to test the script without making actual changes.

You will need to provide the following information in the CSV file:
LicenseName: The name of the ESU license to used.
licenseResourceGroupName: The name of the resource group where the ESU license object is located.
ServerResourceGroupName: The name of the resource group where the ARC server object is located.
Name (or ARCServerName): The name of the ARC server object.
AssignESULicense: TRUE or FALSE depending on if you want to assign or unlink the license from the ARC server object.
LicenseSubscriptionId (Optional): The subscription ID where the license is located. This column always takes precedence over command line parameters. If not provided, uses script parameter or defaults to ARC server subscription.

#>

##############################
#Parameters definition block #
##############################

param(
    [Parameter(Mandatory=$true, HelpMessage="The ID of the subscription where the ARC servers are located.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid subscription ID.")]
    [Alias("sub")]
    [string]$subscriptionId,

    [Parameter(Mandatory=$false, HelpMessage="The ID of the subscription where the ESU licenses are located. If not provided, will use the same subscription as ARC servers.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid subscription ID.")]
    [Alias("licenseSub")]
    [string]$licenseSubscriptionId,

    [Parameter(Mandatory=$false, HelpMessage="The tenant ID of the Microsoft Entra instance used for authentication.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid tenant ID.")]
    [string]$tenantId,

    [Parameter(Mandatory=$false, HelpMessage="The application (client) ID as shown under App Registrations that will be used to authenticate to the Azure API.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid application ID.")]
    [string]$appID,

    [Parameter(Mandatory=$false, HelpMessage="A valid (non expired) client secret for App Registration that will be used to authenticate to the Azure API.")]
    [Alias("s","secret","sec")]
    [string]$clientSecret,

    [Parameter(Mandatory=$true, HelpMessage="The region where the license will be created.")]
    [ValidateNotNullOrEmpty()]
    [Alias("l")]
    [string]$location,

    [Parameter (Mandatory=$true, HelpMessage="The full path to the CSV file containing the list of ESU eligible resources.")]
    [ValidateScript({
        if (-not (Test-Path $_ -PathType Leaf)) {
            throw "CSV file does not exist: $_"
        }
        if (-not ($_ -match '\.csv$')) {
            throw "File must have .csv extension: $_"
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

    [Parameter(Mandatory=$false, HelpMessage="Perform a dry run without making actual changes. Shows what would be done.")]
    [Alias("whatif")]
    [switch]$DryRun
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
    RequiredCSVColumns = @('LicenseName', 'licenseResourceGroupName', 'ServerResourceGroupName', 'Name', 'AssignESULicense')
}

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
        [string]$subscriptionId,
        [string]$licenseSubscriptionId,
        [string]$licenseResourceGroupName,
        [string]$licenseName,
        [string]$ARCServerName,
        [string]$serverResourceGroupName,
        [string]$location,
        [string]$token,
        [switch]$unassign,
        [switch]$dryRun
    )

    try {
        # Validate required parameters
        if ([string]::IsNullOrWhiteSpace($subscriptionId)) { throw "subscriptionId is required" }
        if ([string]::IsNullOrWhiteSpace($licenseSubscriptionId)) { throw "licenseSubscriptionId is required" }
        if ([string]::IsNullOrWhiteSpace($licenseResourceGroupName)) { throw "licenseResourceGroupName is required" }
        if ([string]::IsNullOrWhiteSpace($licenseName)) { throw "licenseName is required" }
        if ([string]::IsNullOrWhiteSpace($ARCServerName)) { throw "ARCServerName is required" }
        if ([string]::IsNullOrWhiteSpace($serverResourceGroupName)) { throw "serverResourceGroupName is required" }
        if ([string]::IsNullOrWhiteSpace($location)) { throw "location is required" }

        $apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$serverResourceGroupName/providers/Microsoft.HybridCompute/machines/$ARCServerName/licenseProfiles/default?api-version=$($script:CONFIG.ApiVersion)"
        $licenseID = "/subscriptions/$licenseSubscriptionId/resourceGroups/$licenseResourceGroupName/providers/Microsoft.HybridCompute/licenses/$licenseName" 
        $method = "PUT"

        # Use provided token or get a bearer token from the App
        if ($token) {
            $bearerToken = $token
        } else {
            $bearerToken = Get-AzureADBearerToken -appID $appID -clientSecret $clientSecret -tenantId $tenantId 
            if ([string]::IsNullOrWhiteSpace($bearerToken)) {
                throw "Failed to obtain authentication token"
            }
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

        # Handle dry-run mode
        if ($dryRun) {
            $action = if ($unassign) { "unlink" } else { "assign" }
            Write-Logfile "[DRY RUN] Would $action ESU license '$licenseName' to/from server '$ARCServerName'" "INFO"
            Write-Logfile "[DRY RUN] API Endpoint: $apiEndpoint" "INFO"
            Write-Logfile "[DRY RUN] Request Body: $requestBodyJson" "INFO"
            return $true
        }

        # Sends the PUT request to update the license
        try {
            Invoke-RestMethod -Uri $apiEndpoint -Method $method -Headers $headers -Body $requestBodyJson | Out-Null
            
            $action = if ($unassign) { "unlinked" } else { "assigned" }
            Write-Logfile "ESU license '$licenseName' successfully $action to/from server '$ARCServerName'" "SUCCESS"
            return $true
        } catch {
            throw $_
        }
        
    } catch {
        $action = if ($unassign) { "unlink" } else { "assign" }
        $errorMessage = "Failed to $action ESU license '$licenseName' to/from server '$ARCServerName': $($_.Exception.Message)"
        Write-Logfile $errorMessage "ERROR"
        
        # Log additional details for debugging
        if ($_.Exception.Response) {
            try {
                $errorDetails = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($errorDetails)
                $responseBody = $reader.ReadToEnd()
                Write-Logfile "API Error Details: $responseBody" "ERROR"
            } catch {
                Write-Logfile "Could not read error response details" "WARNING"
            }
        }
        return $false
    }
}

function Test-CSVRowData {
    param(
        [PSCustomObject]$row,
        [int]$rowNumber
    )
    
    $isValid = $true
    $errors = @()
    
    # Check required fields
    $requiredFields = @{
        'LicenseName' = $row.LicenseName
        'licenseResourceGroupName' = $row.licenseResourceGroupName
        'ServerResourceGroupName' = $row.ServerResourceGroupName
        'Name' = $row.Name
        'AssignESULicense' = $row.AssignESULicense
    }
    
    foreach ($field in $requiredFields.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($field.Value)) {
            $errors += "Missing or empty required field: $($field.Key)"
            $isValid = $false
        }
    }
    
    # Validate AssignESULicense values
    if ($row.AssignESULicense -notin @('True', 'False', 'true', 'false', 'TRUE', 'FALSE')) {
        $errors += "AssignESULicense must be 'True' or 'False', got: '$($row.AssignESULicense)'"
        $isValid = $false
    }
    
    # Validate subscription ID format if provided
    if ($row.PSObject.Properties['LicenseSubscriptionId'] -and 
        ![string]::IsNullOrWhiteSpace($row.LicenseSubscriptionId) -and
        $row.LicenseSubscriptionId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        $errors += "Invalid LicenseSubscriptionId format: '$($row.LicenseSubscriptionId)'"
        $isValid = $false
    }
    
    if (-not $isValid) {
        Write-Logfile "Row $rowNumber validation errors: $($errors -join '; ')" "ERROR"
    }
    
    return $isValid
}

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
                Write-Logfile "All authentication attempts failed. Exiting." "ERROR"
                return $null
            } else {
                Write-Logfile "Retrying in $($script:CONFIG.RetryDelaySeconds) seconds..." "INFO"
                Start-Sleep -Seconds $script:CONFIG.RetryDelaySeconds
            }
        }    
    }
    
    return $null
}

function Write-Logfile  {
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
        exit
    }
} elseif ($tenantId -and $appID -and $clientSecret) {
    Write-Host "Getting authentication token from Microsoft Entra ID" -ForegroundColor Green
    $token = Get-AzureADBearerToken -appID $appID -clientSecret $clientSecret -tenantId $tenantId 
} else {
    Write-Host "You need to provide either the tenant, appID and clientSecrets parameters or a valid authentication token object.`nExiting." -ForegroundColor Red
    exit
}

Write-Host ""
Write-Host "=============================================="
if ($DryRun) {
    Write-Host "DRY RUN MODE - No actual changes will be made"
    Write-Host "=============================================="
}
Write-Host "Starting ESU license assignments from CSV file"
Write-Host "=============================================="

If (![string]::IsNullOrWhiteSpace($logFileName)) {Start-Transcript -Path $logFileName}

# Validate CSV file and import data
try {
    $data = Import-Csv -Path $csvFilePath
    if ($data.Count -eq 0) {
        Write-Logfile "CSV file is empty or has no data rows" "ERROR"
        exit 1
    }
    Write-Logfile "Successfully imported $($data.Count) rows from CSV file" "INFO"
} catch {
    Write-Logfile "Failed to import CSV file: $($_.Exception.Message)" "ERROR"
    exit 1
}

# Validate required CSV columns
$missingColumns = $script:CONFIG.RequiredCSVColumns | Where-Object { $_ -notin $data[0].PSObject.Properties.Name }
if ($missingColumns) {
    Write-Logfile "Missing required CSV columns: $($missingColumns -join ', ')" "ERROR"
    exit 1
}

# Initialize counters for summary
$successCount = 0
$errorCount = 0
$skipCount = 0

# Process each row with progress tracking
$totalRows = $data.Count
$currentRow = 0

foreach ($row in $data) {
    $currentRow++
    $percentComplete = [math]::Round(($currentRow / $totalRows) * 100, 1)
    Write-Progress -Activity "Processing ESU License Assignments" -Status "Processing row $currentRow of $totalRows ($percentComplete%)" -PercentComplete $percentComplete
    
    # Validate row data
    if (-not (Test-CSVRowData -row $row -rowNumber $currentRow)) {
        $skipCount++
        continue
    }
         
        # Determine which subscription to use for the license
        # Priority: 1) CSV LicenseSubscriptionId column (always takes precedence), 2) Script parameter, 3) ARC server subscription (backward compatibility)
        
        if ($row.PSObject.Properties['LicenseSubscriptionId'] -and ![string]::IsNullOrWhiteSpace($row.LicenseSubscriptionId)) {
            # CSV column always takes precedence if provided
            $currentLicenseSubscriptionId = $row.LicenseSubscriptionId
            Write-Verbose "Using license subscription from CSV: $currentLicenseSubscriptionId"
        }
        elseif (![string]::IsNullOrWhiteSpace($licenseSubscriptionId)) {
            # Use command line parameter if no CSV value
            $currentLicenseSubscriptionId = $licenseSubscriptionId
            Write-Verbose "Using license subscription from parameter: $currentLicenseSubscriptionId"
        }
        else {
            # Fall back to ARC server subscription for backward compatibility
            $currentLicenseSubscriptionId = $subscriptionId
            Write-Verbose "Using ARC server subscription for license: $currentLicenseSubscriptionId"
        }

        #Assign the license to the server if requested from the CSV file (AssignESULicense column shoud say TRUE for assignment or FALSE for unlinking)
        switch ($row.AssignESULicense) {
            "True" {
                Write-Logfile "Assigning ESU license ($($row.LicenseName)) to server ($($row.name)) [License Sub: $currentLicenseSubscriptionId]" "INFO"
                
                $params = @{
                    'subscriptionId' = $subscriptionId
                    'licenseSubscriptionId' = $currentLicenseSubscriptionId
                    'tenantId' = $tenantId
                    'appID' = $appID
                    'clientSecret' = $clientSecret
                    'token' = $token
                    'licenseResourceGroupName' = $row.licenseResourceGroupName
                    'licenseName' = $row.LicenseName
                    'serverResourceGroupName' = $row.ServerResourceGroupName
                    'ARCServerName' = $row.Name
                    'location' = $location
                    'dryRun' = $DryRun
                }
                
                $result = AssignESULicense @params
                if ($result) { $successCount++ } else { $errorCount++ }
              }

            "False" {
                Write-Logfile "Unlinking ESU license ($($row.LicenseName)) from server ($($row.name)) [License Sub: $currentLicenseSubscriptionId]" "INFO"

                $params = @{
                    'subscriptionId' = $subscriptionId
                    'licenseSubscriptionId' = $currentLicenseSubscriptionId
                    'tenantId' = $tenantId
                    'appID' = $appID
                    'clientSecret' = $clientSecret
                    'token' = $token
                    'licenseResourceGroupName' = $row.licenseResourceGroupName
                    'licenseName' = $row.LicenseName
                    'serverResourceGroupName' = $row.ServerResourceGroupName
                    'ARCServerName' = $row.Name
                    'location' = $location
                    'unassign' = $true
                    'dryRun' = $DryRun
                }

                $result = AssignESULicense @params
                if ($result) { $successCount++ } else { $errorCount++ }
              }

            Default {
                Write-Logfile "Missing or invalid license assignment action for server '$($row.name)' and license '$($row.LicenseName)'. Expected 'True' or 'False', got '$($row.AssignESULicense)'" "WARNING"
                $skipCount++
            }
        }

    }   

# Complete progress tracking
Write-Progress -Activity "Processing ESU License Assignments" -Completed

# Display summary
Write-Host ""
Write-Host "=============================================="
if ($DryRun) {
    Write-Host "DRY RUN - ESU License Assignment Summary"
} else {
    Write-Host "ESU License Assignment Summary"
}
Write-Host "=============================================="
Write-Logfile "Total rows processed: $totalRows" "INFO"
Write-Logfile "Successful operations: $successCount" "SUCCESS"
Write-Logfile "Failed operations: $errorCount" $(if ($errorCount -gt 0) { "ERROR" } else { "INFO" })
Write-Logfile "Skipped operations: $skipCount" $(if ($skipCount -gt 0) { "WARNING" } else { "INFO" })

if ($DryRun) {
    Write-Logfile "Dry run completed successfully. No actual changes were made." "INFO"
    $exitCode = 0
} elseif ($errorCount -gt 0) {
    Write-Logfile "Script completed with errors. Please review the log for details." "WARNING"
    $exitCode = 1
} else {
    Write-Logfile "Script completed successfully." "SUCCESS"
    $exitCode = 0
}
    
If (![string]::IsNullOrWhiteSpace($logFileName)) {Stop-Transcript}

exit $exitCode



############################
# End of Main script block #
############################