<#
//-----------------------------------------------------------------------

THE SUBJECT SCRIPT IS PROVIDED "AS IS" WITHOUT ANY WARRANTY OF ANY KIND AND SHOULD ONLY BE USED FOR TESTING OR DEMO PURPOSES.
YOU ARE FREE TO REUSE AND/OR MODIFY THE CODE TO FIT YOUR NEEDS

//-----------------------------------------------------------------------

.SYNOPSIS
Unlinks Windows Server ESU licenses from their Azure Arc servers and then deletes the license resources in bulk.

.DESCRIPTION
This script decommissions Azure Arc ESU license resources (Microsoft.HybridCompute/licenses), for example after the
Windows Server 2012 and Windows Server 2012 R2 ESU period ended on October 13, 2026.

Licenses are selected in one of two ways:
1. CSV mode (-csvFilePath): each row names a license with LicenseName, LicenseResourceGroupName, and an optional
   LicenseSubscriptionId. A row without LicenseSubscriptionId uses -licenseSubscriptionId.
2. Discovery mode (-licenseSubscriptionId without -csvFilePath): every ESU license in the subscription, or in
   -licenseResourceGroupName when provided, is selected.

In both modes, only licenses whose target is listed in -target are processed. The default is Windows Server 2012 and
Windows Server 2012 R2; Windows Server 2016 licenses are processed only when -target explicitly includes them.

For each selected license, the script:
1. Finds the Azure Arc servers assigned to the license with an Azure Resource Graph query. The query searches only the
   subscription that contains the license; servers in other subscriptions are not detected.
2. Exports a before-change inventory CSV that lists every selected license, its properties, and its assigned servers.
3. Unlinks each server with the documented license profile PUT that sends an empty esuProfile. The script first reads
   the license profile and skips a server when the profile also contains Software Assurance or product profile
   settings, because the documented PUT could change them. The request location comes from the license profile;
   -location is used only when the profile does not return one.
4. Reads each license profile again to confirm that the license is no longer assigned.
5. Deletes the license only when every discovered server was unlinked and confirmed. Otherwise the license is kept,
   the error is logged, and the script continues with the next license.

Microsoft bills a deleted or deactivated license for up to five calendar days after the change. Deletion does not
exempt you from back-billing. Review the official ESU billing guidance before running this script.

The script supports two authentication methods:
1. Service Principal authentication (requires tenantId, appID and clientSecret)
2. User token authentication (requires a valid Microsoft Entra ID authentication token)

Exit codes:
0 - Every processed license succeeded, or nothing needed to be processed. Declined confirmations are not failures.
1 - Fatal error: authentication, CSV file, license discovery, or inventory export failure. No license is changed.
2 - Partial failure: at least one license could not be found, unlinked, verified, or deleted.

.NOTES
File Name : BulkDeleteESULicenses.ps1
Author    : David De Backer
Version   : 1.0
Date      : 26-October-2026
Tested on : PowerShell Version 7.6.5
Module    : Azure PowerShell Az.Accounts version 5.5.2
Requires  : Powershell Core version 7.x or later
Product   : Azure ARC

.CHANGELOG
v1.0 - Initial release.

.LINK
https://learn.microsoft.com/azure/azure-arc/servers/api-extended-security-updates
https://learn.microsoft.com/azure/azure-arc/servers/billing-extended-security-updates
https://learn.microsoft.com/rest/api/hybridcompute/license-profiles
https://learn.microsoft.com/rest/api/azureresourcegraph/resourcegraph/resources/resources

.EXAMPLE-1
./Scripts/windows/BulkDeleteESULicenses.ps1 -licenseSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-clientSecret "your_application_secret_value" `
-licenseResourceGroupName "rg-ARC-ESULicenses" `
-DryRun

.EXAMPLE-2
$authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
./Scripts/windows/BulkDeleteESULicenses.ps1 -licenseSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-csvFilePath "C:\Temp\ESU Licenses To Delete.csv" `
-userToken $authToken `
-inventoryFilePath "C:\Temp\ESU-deletion-inventory.csv" `
-logFileName "C:\Temp\ESU-deletion.log"

Example 1 uses service principal authentication and previews every Windows Server 2012 and 2012 R2 ESU license in one
resource group without changing anything.
Example 2 uses Microsoft Entra ID token authentication, reads the licenses from a CSV file, and asks for confirmation
before each license is unlinked and deleted. Add -Confirm:$false only for reviewed, unattended runs.

#>

##############################
#Parameters definition block #
##############################

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Discovery')]
param(
    [Parameter(Mandatory=$true, ParameterSetName='Discovery', HelpMessage="The ID of the subscription that contains the ESU licenses to delete.")]
    [Parameter(Mandatory=$false, ParameterSetName='Csv', HelpMessage="The default subscription ID for CSV rows without a LicenseSubscriptionId value.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid subscription ID.")]
    [Alias("licenseSub", "subscriptionId")]
    [string]$licenseSubscriptionId,

    [Parameter(Mandatory=$false, ParameterSetName='Discovery', HelpMessage="Limits discovery to the ESU licenses in this resource group.")]
    [ValidatePattern('^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$', ErrorMessage="The resource group name '{0}' did not pass validation (1-90 alphanumeric characters)")]
    [Alias("lrg")]
    [string]$licenseResourceGroupName,

    [Parameter(Mandatory=$true, ParameterSetName='Csv', HelpMessage="The full path to the CSV file listing the ESU licenses to delete.")]
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
    [string]$csvFilePath,

    [Parameter(Mandatory=$false, HelpMessage="The license targets that may be deleted. Defaults to Windows Server 2012 and Windows Server 2012 R2.")]
    [ValidateSet("Windows Server 2012", "Windows Server 2012 R2", "Windows Server 2016", ErrorMessage="Value '{0}' is invalid. Try one of: '{1}'")]
    [string[]]$target = @("Windows Server 2012", "Windows Server 2012 R2"),

    [Parameter(Mandatory=$false, HelpMessage="Fallback region for the unlink request when a license profile does not return its location.")]
    [ValidateNotNullOrEmpty()]
    [Alias("l")]
    [string]$location,

    [Parameter(Mandatory=$false, HelpMessage="The tenant ID of the Microsoft Entra instance used for authentication.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid tenant ID.")]
    [string]$tenantId,

    [Parameter(Mandatory=$false, HelpMessage="The application (client) ID as shown under App Registrations that will be used to authenticate to the Azure API.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid application ID.")]
    [string]$appID,

    [Parameter(Mandatory=$false, HelpMessage="A valid (non expired) client secret for App Registration that will be used to authenticate to the Azure API.")]
    [Alias("s", "secret", "sec")]
    [string]$clientSecret,

    [Parameter(Mandatory=$false, HelpMessage="The bearer token obtained from the Azure API by the user. If not provided, the script will require the appID, clientSecret and tenantId parameters.")]
    [Alias("token")]
    [System.Object]$userToken,

    [Parameter(Mandatory=$false, HelpMessage="The path of the before-change inventory CSV. Defaults to a timestamped file in the current directory.")]
    [ValidateNotNullOrEmpty()]
    [Alias("inventory")]
    [string]$inventoryFilePath,

    [Parameter(Mandatory=$false, HelpMessage="The name of the log file to be created.")]
    [Alias("log")]
    [string]$logFileName,

    [Parameter(Mandatory=$false, HelpMessage="Perform a dry run without making actual changes. Shows what would be done.")]
    [Alias("Preview")]
    [switch]$DryRun
)

#####################################
#End of Parameters definition block #
#####################################



##############################
# Variables definition block #
##############################

$script:CONFIG = @{
    # GA 2026-09-01 was verified for licenses (list, get, delete; includes the Windows Server 2016 target) and
    # licenseProfiles (get, create-or-update; includes softwareAssurance and productProfile).
    HybridComputeApiVersion = "2026-09-01"
    ResourceGraphApiVersion = "2024-04-01"
    ManagementEndpoint = "https://management.azure.com"
    AzureResourceUrl = "https://management.azure.com/"
    LoginEndpoint = "https://login.microsoftonline.com"
    RequiredCSVColumns = @('LicenseName', 'LicenseResourceGroupName')
    ResourceGraphPageSize = 1000
    UnlinkVerificationAttempts = 6
    UnlinkVerificationDelaySeconds = 10
}

#########################################
# End of the variables definition block #
#########################################



################################
# Function(s) definition block #
################################

function Write-Logfile {
    param(
        [Parameter(Mandatory=$true)]
        [Alias("m")]
        [string]$message,

        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$level] $message"

    switch ($level) {
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        default { Write-Host $logMessage }
    }

    # Write-Host output is captured by Start-Transcript when active.
}

function Get-AzureADBearerToken {
    param(
        [string]$appID,
        [string]$clientSecret,
        [string]$tenantId,
        [int]$retryCount = 3,
        [int]$retryDelaySeconds = 5
    )

    $oAuthEndpoint = "$($script:CONFIG.LoginEndpoint)/$tenantId/oauth2/token"

    $authbody = @{
        grant_type = "client_credentials"
        client_id = $appID
        client_secret = $clientSecret
        resource = $script:CONFIG.AzureResourceUrl
    }

    Write-Verbose "Authenticating..."

    for ($attempt = 1; $attempt -le $retryCount; $attempt++) {
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
            Write-Logfile "Authentication attempt $attempt failed: $($_.Exception.Message)" "WARNING"

            if ($attempt -eq $retryCount) {
                Write-Logfile "All authentication attempts failed. Exiting." "ERROR"
                return $null
            }

            Write-Logfile "Retrying in $retryDelaySeconds seconds..." "INFO"
            Start-Sleep -Seconds $retryDelaySeconds
        }
    }

    return $null
}

function Get-ArmHeaders {
    param(
        [string]$bearerToken
    )

    return @{
        "Authorization" = "Bearer $bearerToken"
        "Content-Type" = "application/json"
    }
}

function Get-HttpStatusCode {
    param(
        [System.Management.Automation.ErrorRecord]$errorRecord
    )

    if ($errorRecord.Exception.Response -and $null -ne $errorRecord.Exception.Response.StatusCode) {
        return [int]$errorRecord.Exception.Response.StatusCode
    }

    return $null
}

function Get-RestErrorMessage {
    param(
        [System.Management.Automation.ErrorRecord]$errorRecord
    )

    $message = $errorRecord.Exception.Message
    if ($errorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($errorRecord.ErrorDetails.Message)) {
        $message = "$message $($errorRecord.ErrorDetails.Message)"
    }

    # ARM error bodies can contain subscription, tenant, and principal IDs; keep them out of the console and log.
    $message = $message -replace '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<redacted-id>'

    $statusCode = Get-HttpStatusCode -errorRecord $errorRecord
    if ($statusCode) {
        return "HTTP $statusCode - $message"
    }

    return $message
}

function ConvertFrom-ArmResourceId {
    param(
        [string]$resourceId
    )

    if ([string]::IsNullOrWhiteSpace($resourceId)) {
        return $null
    }

    # Expected layout: /subscriptions/{id}/resourceGroups/{rg}/providers/{namespace}/{type}/{name}[/...]
    $segments = $resourceId.Trim('/') -split '/'
    if ($segments.Count -lt 8 -or
        $segments[0] -ne 'subscriptions' -or
        $segments[2] -ne 'resourceGroups' -or
        $segments[4] -ne 'providers') {
        return $null
    }

    return [pscustomobject]@{
        SubscriptionId = $segments[1]
        ResourceGroupName = $segments[3]
        ResourceName = $segments[7]
    }
}

function Get-ESULicenseResourceId {
    param(
        [string]$subscriptionId,
        [string]$resourceGroupName,
        [string]$licenseName
    )

    return "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.HybridCompute/licenses/$licenseName"
}

function Test-LicenseIdMatch {
    param(
        [string]$assignedLicense,
        [string]$licenseId
    )

    if ([string]::IsNullOrWhiteSpace($assignedLicense) -or [string]::IsNullOrWhiteSpace($licenseId)) {
        return $false
    }

    # Azure resource IDs are case-insensitive; -eq is case-insensitive in PowerShell.
    return ($assignedLicense.Trim().TrimEnd('/') -eq $licenseId.Trim().TrimEnd('/'))
}

function Resolve-LicenseSubscriptionId {
    param(
        [PSCustomObject]$row,
        [string]$licenseSubscriptionId
    )

    if ($row.PSObject.Properties['LicenseSubscriptionId'] -and -not [string]::IsNullOrWhiteSpace($row.LicenseSubscriptionId)) {
        return $row.LicenseSubscriptionId.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($licenseSubscriptionId)) {
        return $licenseSubscriptionId
    }

    return $null
}

function Test-LicenseCsvRow {
    param(
        [PSCustomObject]$row,
        [int]$rowNumber,
        [string]$licenseSubscriptionId
    )

    $errors = @()

    if ([string]::IsNullOrWhiteSpace($row.LicenseName)) {
        $errors += "Missing or empty required field: LicenseName"
    } elseif ($row.LicenseName -notmatch '^[a-zA-Z0-9_\-\.]+$') {
        $errors += "LicenseName contains unsupported characters: '$($row.LicenseName)'"
    }

    if ([string]::IsNullOrWhiteSpace($row.LicenseResourceGroupName)) {
        $errors += "Missing or empty required field: LicenseResourceGroupName"
    } elseif ($row.LicenseResourceGroupName -notmatch '^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$') {
        $errors += "LicenseResourceGroupName is not a valid resource group name: '$($row.LicenseResourceGroupName)'"
    }

    $resolvedSubscriptionId = Resolve-LicenseSubscriptionId -row $row -licenseSubscriptionId $licenseSubscriptionId
    if ([string]::IsNullOrWhiteSpace($resolvedSubscriptionId)) {
        $errors += "No license subscription: provide LicenseSubscriptionId in the row or the -licenseSubscriptionId parameter"
    } elseif ($resolvedSubscriptionId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        $errors += "LicenseSubscriptionId is not a valid subscription ID format"
    }

    if ($errors.Count -gt 0) {
        Write-Logfile "Row $rowNumber validation errors: $($errors -join '; ')" "ERROR"
        return $false
    }

    return $true
}

function Test-LicenseTargetIncluded {
    param(
        [string]$licenseTarget,
        [string[]]$target
    )

    if ([string]::IsNullOrWhiteSpace($licenseTarget)) {
        return $false
    }

    return ($target -contains $licenseTarget.Trim())
}

function ConvertTo-LicensePlanItem {
    param(
        [object]$license,
        [string]$licenseName,
        [string]$licenseResourceGroupName,
        [string]$licenseSubscriptionId
    )

    $item = [pscustomobject]@{
        LicenseId = $null
        LicenseName = $licenseName
        LicenseResourceGroupName = $licenseResourceGroupName
        LicenseSubscriptionId = $licenseSubscriptionId
        LicenseLocation = $null
        Target = $null
        State = $null
        Edition = $null
        CoreType = $null
        Processors = $null
        AssignedLicensesReported = $null
        ImmutableId = $null
        LicenseDetailsJson = $null
        TagsJson = $null
        Servers = [System.Collections.Generic.List[object]]::new()
        ServerResults = [System.Collections.Generic.List[object]]::new()
        Status = 'Pending'
        Message = ''
    }

    if ($null -ne $license) {
        $parsedId = ConvertFrom-ArmResourceId -resourceId $license.id
        $details = $license.properties.licenseDetails

        if ($parsedId) {
            $item.LicenseId = [string]$license.id
            $item.LicenseResourceGroupName = $parsedId.ResourceGroupName
            $item.LicenseSubscriptionId = $parsedId.SubscriptionId
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$license.name)) {
            $item.LicenseName = [string]$license.name
        }
        $item.LicenseLocation = [string]$license.location
        if ($null -ne $details) {
            $item.Target = [string]$details.target
            $item.State = [string]$details.state
            $item.Edition = [string]$details.edition
            $item.CoreType = [string]$details.type
            $item.Processors = $details.processors
            $item.AssignedLicensesReported = $details.assignedLicenses
            $item.ImmutableId = [string]$details.immutableId
            $item.LicenseDetailsJson = $details | ConvertTo-Json -Depth 10 -Compress
        }
        if ($null -ne $license.tags) {
            $item.TagsJson = $license.tags | ConvertTo-Json -Depth 5 -Compress
        }
    }

    if ([string]::IsNullOrWhiteSpace($item.LicenseId) -and
        -not [string]::IsNullOrWhiteSpace($item.LicenseSubscriptionId) -and
        -not [string]::IsNullOrWhiteSpace($item.LicenseResourceGroupName) -and
        -not [string]::IsNullOrWhiteSpace($item.LicenseName)) {
        $item.LicenseId = Get-ESULicenseResourceId -subscriptionId $item.LicenseSubscriptionId -resourceGroupName $item.LicenseResourceGroupName -licenseName $item.LicenseName
    }

    return $item
}

function Get-ESULicense {
    param(
        [string]$licenseResourceId,
        [string]$bearerToken
    )

    $uri = "$($script:CONFIG.ManagementEndpoint)$licenseResourceId`?api-version=$($script:CONFIG.HybridComputeApiVersion)"
    return Invoke-RestMethod -Uri $uri -Method GET -Headers (Get-ArmHeaders -bearerToken $bearerToken) -ErrorAction Stop
}

function Get-ESULicenseList {
    param(
        [string]$subscriptionId,
        [string]$resourceGroupName,
        [string]$bearerToken
    )

    $scope = "/subscriptions/$subscriptionId"
    if (-not [string]::IsNullOrWhiteSpace($resourceGroupName)) {
        $scope = "$scope/resourceGroups/$resourceGroupName"
    }

    $uri = "$($script:CONFIG.ManagementEndpoint)$scope/providers/Microsoft.HybridCompute/licenses?api-version=$($script:CONFIG.HybridComputeApiVersion)"
    $headers = Get-ArmHeaders -bearerToken $bearerToken
    $licenses = [System.Collections.Generic.List[object]]::new()

    while (-not [string]::IsNullOrWhiteSpace($uri)) {
        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ErrorAction Stop
        foreach ($license in @($response.value)) {
            if ($null -ne $license) {
                $licenses.Add($license)
            }
        }

        $nextLink = [string]$response.nextLink
        if ($nextLink -eq $uri) {
            break
        }
        $uri = $nextLink
    }

    return $licenses.ToArray()
}

function Get-ResourceGraphAssignmentQuery {
    param(
        [string]$licenseSubscriptionId
    )

    # The subscription ID is validated as a GUID before it reaches this query.
    $licensePrefix = "/subscriptions/$($licenseSubscriptionId.ToLowerInvariant())/"

    return @"
resources
| where type =~ 'microsoft.hybridcompute/machines/licenseprofiles'
| extend assignedLicense = tolower(tostring(properties.esuProfile.assignedLicense))
| where assignedLicense startswith '$licensePrefix'
| project id, location, assignedLicense
| order by id asc
"@
}

function Get-ResourceGraphLicenseAssignment {
    param(
        [string]$licenseSubscriptionId,
        [string]$bearerToken
    )

    $uri = "$($script:CONFIG.ManagementEndpoint)/providers/Microsoft.ResourceGraph/resources?api-version=$($script:CONFIG.ResourceGraphApiVersion)"
    $headers = Get-ArmHeaders -bearerToken $bearerToken
    $query = Get-ResourceGraphAssignmentQuery -licenseSubscriptionId $licenseSubscriptionId
    $assignments = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null

    do {
        $options = @{
            '$top' = $script:CONFIG.ResourceGraphPageSize
            resultFormat = 'objectArray'
        }
        if (-not [string]::IsNullOrWhiteSpace($skipToken)) {
            $options['$skipToken'] = $skipToken
        }

        $requestBody = @{
            subscriptions = @($licenseSubscriptionId)
            query = $query
            options = $options
        }

        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body ($requestBody | ConvertTo-Json -Depth 5) -ErrorAction Stop

        foreach ($row in @($response.data)) {
            if ($null -eq $row) {
                continue
            }

            $parsedId = ConvertFrom-ArmResourceId -resourceId ([string]$row.id)
            if ($null -eq $parsedId) {
                Write-Logfile "Ignoring a Resource Graph row with an unexpected license profile ID format." "WARNING"
                continue
            }

            $assignments.Add([pscustomobject]@{
                LicenseId = [string]$row.assignedLicense
                ProfileId = [string]$row.id
                ServerSubscriptionId = $parsedId.SubscriptionId
                ServerResourceGroupName = $parsedId.ResourceGroupName
                ServerName = $parsedId.ResourceName
                ServerLocation = [string]$row.location
            })
        }

        $skipToken = [string]$response.'$skipToken'

        # Missing assignments would let a still-assigned license be deleted, so truncation is fatal.
        if ([string]::IsNullOrWhiteSpace($skipToken) -and [string]$response.resultTruncated -eq 'true') {
            throw "Azure Resource Graph returned truncated results without a continuation token."
        }
    } while (-not [string]::IsNullOrWhiteSpace($skipToken))

    return $assignments.ToArray()
}

function Test-ConfiguredValue {
    param(
        [object]$value
    )

    if ($null -eq $value) {
        return $false
    }
    if ($value -is [string]) {
        return -not [string]::IsNullOrWhiteSpace($value)
    }
    if ($value -is [System.Collections.IDictionary]) {
        return $value.Count -gt 0
    }
    if ($value -is [System.Collections.IEnumerable]) {
        return @($value).Count -gt 0
    }
    if ($value -is [System.Management.Automation.PSCustomObject]) {
        return @($value.PSObject.Properties).Count -gt 0
    }

    return $true
}

function Get-LicenseProfileBlockingSetting {
    param(
        [object]$licenseProfile
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $properties = $licenseProfile.properties
    if ($null -eq $properties) {
        return $reasons.ToArray()
    }

    # The documented unlink PUT omits these billing-relevant settings, and Microsoft does not document whether
    # omitting them preserves or resets them. A server that has them is skipped instead of risking a change.
    $softwareAssurance = $properties.softwareAssurance
    if ($null -ne $softwareAssurance -and $null -ne $softwareAssurance.softwareAssuranceCustomer) {
        $reasons.Add("softwareAssurance.softwareAssuranceCustomer=$($softwareAssurance.softwareAssuranceCustomer)")
    }

    $productProfile = $properties.productProfile
    if ($null -ne $productProfile) {
        foreach ($property in $productProfile.PSObject.Properties) {
            if (Test-ConfiguredValue -value $property.Value) {
                $reasons.Add("productProfile.$($property.Name)")
            }
        }
    }

    return $reasons.ToArray()
}

function Get-UnlinkRequestBody {
    param(
        [string]$location,
        [object]$tags
    )

    $requestBody = [ordered]@{
        location = $location
        properties = @{
            esuProfile = @{}
        }
    }

    if (Test-ConfiguredValue -value $tags) {
        $requestBody['tags'] = $tags
    }

    return $requestBody
}

function Get-LicenseProfileUri {
    param(
        [object]$server
    )

    return "$($script:CONFIG.ManagementEndpoint)/subscriptions/$($server.ServerSubscriptionId)/resourceGroups/$($server.ServerResourceGroupName)/providers/Microsoft.HybridCompute/machines/$($server.ServerName)/licenseProfiles/default?api-version=$($script:CONFIG.HybridComputeApiVersion)"
}

function Invoke-ESULicenseUnlink {
    param(
        [object]$server,
        [string]$licenseId,
        [string]$fallbackLocation,
        [string]$bearerToken,
        [switch]$preview
    )

    $result = [pscustomobject]@{
        ServerName = $server.ServerName
        ServerResourceGroupName = $server.ServerResourceGroupName
        Outcome = 'Failed'
        Message = ''
    }

    $uri = Get-LicenseProfileUri -server $server
    $headers = Get-ArmHeaders -bearerToken $bearerToken

    try {
        $licenseProfile = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ErrorAction Stop
    } catch {
        $result.Message = "Could not read the license profile: $(Get-RestErrorMessage -errorRecord $_)"
        return $result
    }

    $assignedLicense = [string]$licenseProfile.properties.esuProfile.assignedLicense
    if (-not (Test-LicenseIdMatch -assignedLicense $assignedLicense -licenseId $licenseId)) {
        $result.Outcome = 'AlreadyUnlinked'
        $result.Message = if ([string]::IsNullOrWhiteSpace($assignedLicense)) {
            "No ESU license is assigned anymore."
        } else {
            "The server is now assigned to a different ESU license, which was left unchanged."
        }
        return $result
    }

    $blockingSettings = @(Get-LicenseProfileBlockingSetting -licenseProfile $licenseProfile)
    if ($blockingSettings.Count -gt 0) {
        $result.Outcome = 'Blocked'
        $result.Message = "The license profile also contains $($blockingSettings -join ', '). The documented unlink request could change these settings, so the server was skipped. Unlink it manually after reviewing those settings."
        return $result
    }

    $effectiveLocation = if (-not [string]::IsNullOrWhiteSpace([string]$licenseProfile.location)) {
        [string]$licenseProfile.location
    } else {
        $fallbackLocation
    }
    if ([string]::IsNullOrWhiteSpace($effectiveLocation)) {
        $result.Message = "The license profile did not return a location and -location was not provided."
        return $result
    }

    if ($preview) {
        $result.Outcome = 'WouldUnlink'
        $result.Message = "Validation passed; the server would be unlinked (location '$effectiveLocation')."
        return $result
    }

    $requestBodyJson = Get-UnlinkRequestBody -location $effectiveLocation -tags $licenseProfile.tags | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers -Body $requestBodyJson -ErrorAction Stop | Out-Null
    } catch {
        $result.Message = "The unlink request failed: $(Get-RestErrorMessage -errorRecord $_)"
        return $result
    }

    $attempts = [Math]::Max(1, [int]$script:CONFIG.UnlinkVerificationAttempts)
    $lastVerificationError = $null
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            $currentProfile = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ErrorAction Stop
            $currentLicense = [string]$currentProfile.properties.esuProfile.assignedLicense
            if (-not (Test-LicenseIdMatch -assignedLicense $currentLicense -licenseId $licenseId)) {
                $result.Outcome = 'Unlinked'
                $result.Message = "Unlinked and verified."
                return $result
            }
            $lastVerificationError = $null
        } catch {
            $lastVerificationError = Get-RestErrorMessage -errorRecord $_
        }

        if ($attempt -lt $attempts) {
            Start-Sleep -Seconds $script:CONFIG.UnlinkVerificationDelaySeconds
        }
    }

    $result.Message = if ($lastVerificationError) {
        "The unlink request was sent, but verification failed: $lastVerificationError"
    } else {
        "The unlink request was sent, but the license was still assigned after $attempts verification attempt(s)."
    }
    return $result
}

function Invoke-ESULicenseDeletion {
    param(
        [string]$licenseId,
        [string]$bearerToken
    )

    $uri = "$($script:CONFIG.ManagementEndpoint)$licenseId`?api-version=$($script:CONFIG.HybridComputeApiVersion)"
    Invoke-RestMethod -Uri $uri -Method DELETE -Headers (Get-ArmHeaders -bearerToken $bearerToken) -ErrorAction Stop | Out-Null
}

function Invoke-LicenseDecommission {
    param(
        [object]$planItem,
        [string]$fallbackLocation,
        [string]$bearerToken,
        [switch]$preview
    )

    $prefix = if ($preview) { "[DRY RUN] " } else { "" }

    foreach ($server in $planItem.Servers) {
        $serverResult = Invoke-ESULicenseUnlink -server $server -licenseId $planItem.LicenseId -fallbackLocation $fallbackLocation -bearerToken $bearerToken -preview:$preview
        $planItem.ServerResults.Add($serverResult)

        $serverLabel = "server '$($server.ServerName)' (resource group '$($server.ServerResourceGroupName)')"
        switch ($serverResult.Outcome) {
            'Unlinked' { Write-Logfile "License '$($planItem.LicenseName)': $serverLabel - $($serverResult.Message)" "SUCCESS" }
            'WouldUnlink' { Write-Logfile "$($prefix)License '$($planItem.LicenseName)': $serverLabel - $($serverResult.Message)" "INFO" }
            'AlreadyUnlinked' { Write-Logfile "$($prefix)License '$($planItem.LicenseName)': $serverLabel - $($serverResult.Message)" "INFO" }
            default { Write-Logfile "$($prefix)License '$($planItem.LicenseName)': $serverLabel - $($serverResult.Message)" "ERROR" }
        }
    }

    $failedServers = @($planItem.ServerResults | Where-Object { $_.Outcome -in @('Failed', 'Blocked') })
    if ($failedServers.Count -gt 0) {
        $planItem.Status = 'Failed'
        $planItem.Message = "$($failedServers.Count) server(s) could not be unlinked; the license was not deleted."
        Write-Logfile "$($prefix)License '$($planItem.LicenseName)' was not deleted: $($planItem.Message)" "ERROR"
        return
    }

    if ($preview) {
        $planItem.Status = 'WouldDelete'
        $planItem.Message = "Validation passed for $($planItem.Servers.Count) server(s); the license would be deleted."
        Write-Logfile "$($prefix)License '$($planItem.LicenseName)': $($planItem.Message)" "SUCCESS"
        return
    }

    try {
        Invoke-ESULicenseDeletion -licenseId $planItem.LicenseId -bearerToken $bearerToken
        $planItem.Status = 'Deleted'
        $planItem.Message = "Unlinked from $($planItem.Servers.Count) server(s) and deleted."
        Write-Logfile "License '$($planItem.LicenseName)' deleted." "SUCCESS"
    } catch {
        $planItem.Status = 'Failed'
        $planItem.Message = "The servers were unlinked, but the delete request failed: $(Get-RestErrorMessage -errorRecord $_)"
        Write-Logfile "License '$($planItem.LicenseName)': $($planItem.Message)" "ERROR"
    }
}

function ConvertTo-InventoryRow {
    param(
        [object[]]$planItems,
        [string]$exportedAtUtc
    )

    foreach ($planItem in $planItems) {
        $servers = @($planItem.Servers)
        if ($servers.Count -eq 0) {
            $servers = @($null)
        }

        foreach ($server in $servers) {
            [pscustomobject][ordered]@{
                ExportedAtUtc = $exportedAtUtc
                LicenseName = $planItem.LicenseName
                LicenseResourceGroupName = $planItem.LicenseResourceGroupName
                LicenseSubscriptionId = $planItem.LicenseSubscriptionId
                LicenseId = $planItem.LicenseId
                LicenseLocation = $planItem.LicenseLocation
                Target = $planItem.Target
                State = $planItem.State
                Edition = $planItem.Edition
                CoreType = $planItem.CoreType
                Processors = $planItem.Processors
                AssignedLicensesReported = $planItem.AssignedLicensesReported
                ImmutableId = $planItem.ImmutableId
                LicenseDetailsJson = $planItem.LicenseDetailsJson
                TagsJson = $planItem.TagsJson
                ServerName = if ($server) { $server.ServerName } else { $null }
                ServerResourceGroupName = if ($server) { $server.ServerResourceGroupName } else { $null }
                ServerSubscriptionId = if ($server) { $server.ServerSubscriptionId } else { $null }
                ServerLocation = if ($server) { $server.ServerLocation } else { $null }
                ServerLicenseProfileId = if ($server) { $server.ProfileId } else { $null }
                PlannedAction = if ($server) { 'Unlink server, then delete license' } else { 'Delete license (no assignment found)' }
            }
        }
    }
}

#######################################
# End of Function(s) definition block #
#######################################



#####################
# Main script block #
#####################

if ($userToken) {
    if ($userToken.ExpiresOn -gt (Get-Date)) {
        Write-Host "Using provided Microsoft Entra ID authentication token" -ForegroundColor Green
        $token = ConvertFrom-SecureString -SecureString $userToken.Token -AsPlainText
    } else {
        Write-Host "The provided user token has expired. Please provide a valid token.`nExiting." -ForegroundColor Red
        exit 1
    }
} elseif ($tenantId -and $appID -and $clientSecret) {
    Write-Host "Getting authentication token from Microsoft Entra ID" -ForegroundColor Green
    $token = Get-AzureADBearerToken -appID $appID -clientSecret $clientSecret -tenantId $tenantId
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Host "Failed to obtain an authentication token.`nExiting." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "You need to provide either the tenant, appID and clientSecrets parameters or a valid authentication token object.`nExiting." -ForegroundColor Red
    exit 1
}

$isPreview = $DryRun -or $WhatIfPreference

if (-not [string]::IsNullOrWhiteSpace($logFileName)) {
    Start-Transcript -Path $logFileName -Append -WhatIf:$false -Confirm:$false | Out-Null
}

Write-Host ""
Write-Host "=============================================="
if ($isPreview) {
    Write-Host "DRY RUN MODE - No actual changes will be made"
    Write-Host "=============================================="
}
Write-Host "Starting bulk ESU license unlink and deletion"
Write-Host "=============================================="
Write-Logfile "Selected license targets: $($target -join ', ')" "INFO"

$allItems = [System.Collections.Generic.List[object]]::new()
$planItems = [System.Collections.Generic.List[object]]::new()

if ($PSCmdlet.ParameterSetName -eq 'Csv') {
    try {
        $data = @(Import-Csv -Path $csvFilePath)
    } catch {
        Write-Logfile "Failed to import CSV file: $($_.Exception.Message)" "ERROR"
        if (-not [string]::IsNullOrWhiteSpace($logFileName)) { Stop-Transcript | Out-Null }
        exit 1
    }

    if ($data.Count -eq 0) {
        Write-Logfile "CSV file is empty or has no data rows" "ERROR"
        if (-not [string]::IsNullOrWhiteSpace($logFileName)) { Stop-Transcript | Out-Null }
        exit 1
    }

    $missingColumns = $script:CONFIG.RequiredCSVColumns | Where-Object { $_ -notin $data[0].PSObject.Properties.Name }
    if ($missingColumns) {
        Write-Logfile "Missing required CSV columns: $($missingColumns -join ', ')" "ERROR"
        if (-not [string]::IsNullOrWhiteSpace($logFileName)) { Stop-Transcript | Out-Null }
        exit 1
    }

    Write-Logfile "Imported $($data.Count) row(s) from the CSV file" "INFO"
    $seenLicenseIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $rowNumber = 0

    foreach ($row in $data) {
        $rowNumber++

        if (-not (Test-LicenseCsvRow -row $row -rowNumber $rowNumber -licenseSubscriptionId $licenseSubscriptionId)) {
            $invalidItem = ConvertTo-LicensePlanItem -licenseName ([string]$row.LicenseName) -licenseResourceGroupName ([string]$row.LicenseResourceGroupName)
            $invalidItem.Status = 'Failed'
            $invalidItem.Message = "CSV row $rowNumber failed validation."
            $allItems.Add($invalidItem)
            continue
        }

        $rowSubscriptionId = Resolve-LicenseSubscriptionId -row $row -licenseSubscriptionId $licenseSubscriptionId
        $rowLicenseName = $row.LicenseName.Trim()
        $rowResourceGroupName = $row.LicenseResourceGroupName.Trim()
        $rowLicenseId = Get-ESULicenseResourceId -subscriptionId $rowSubscriptionId -resourceGroupName $rowResourceGroupName -licenseName $rowLicenseName

        if (-not $seenLicenseIds.Add($rowLicenseId)) {
            Write-Logfile "Row $($rowNumber): license '$rowLicenseName' in resource group '$rowResourceGroupName' is listed more than once; the duplicate row is ignored." "WARNING"
            continue
        }

        try {
            $license = Get-ESULicense -licenseResourceId $rowLicenseId -bearerToken $token
            $item = ConvertTo-LicensePlanItem -license $license -licenseName $rowLicenseName -licenseResourceGroupName $rowResourceGroupName -licenseSubscriptionId $rowSubscriptionId
        } catch {
            $item = ConvertTo-LicensePlanItem -licenseName $rowLicenseName -licenseResourceGroupName $rowResourceGroupName -licenseSubscriptionId $rowSubscriptionId
            $item.Status = 'Failed'
            $item.Message = if ((Get-HttpStatusCode -errorRecord $_) -eq 404) {
                "The license was not found."
            } else {
                "The license could not be read: $(Get-RestErrorMessage -errorRecord $_)"
            }
            Write-Logfile "Row $($rowNumber): license '$rowLicenseName' in resource group '$rowResourceGroupName': $($item.Message)" "ERROR"
            $allItems.Add($item)
            continue
        }

        $allItems.Add($item)
        if (-not (Test-LicenseTargetIncluded -licenseTarget $item.Target -target $target)) {
            $item.Status = 'Excluded'
            $item.Message = "Target '$($item.Target)' is not selected by -target; the license was left unchanged."
            Write-Logfile "Row $($rowNumber): license '$($item.LicenseName)': $($item.Message)" "WARNING"
            continue
        }

        $planItems.Add($item)
    }
} else {
    $scopeDescription = if ([string]::IsNullOrWhiteSpace($licenseResourceGroupName)) { "the license subscription" } else { "resource group '$licenseResourceGroupName'" }
    Write-Logfile "Discovering ESU licenses in $scopeDescription..." "INFO"

    try {
        $licenses = @(Get-ESULicenseList -subscriptionId $licenseSubscriptionId -resourceGroupName $licenseResourceGroupName -bearerToken $token)
    } catch {
        Write-Logfile "Failed to list ESU licenses in $($scopeDescription): $(Get-RestErrorMessage -errorRecord $_)" "ERROR"
        if (-not [string]::IsNullOrWhiteSpace($logFileName)) { Stop-Transcript | Out-Null }
        exit 1
    }

    Write-Logfile "Found $($licenses.Count) license resource(s)" "INFO"
    foreach ($license in $licenses) {
        $item = ConvertTo-LicensePlanItem -license $license
        $licenseType = [string]$license.properties.licenseType
        $allItems.Add($item)

        if (-not [string]::IsNullOrWhiteSpace($licenseType) -and $licenseType -ne 'ESU') {
            $item.Status = 'Excluded'
            $item.Message = "License type '$licenseType' is not ESU; the license was left unchanged."
            Write-Logfile "License '$($item.LicenseName)': $($item.Message)" "INFO"
            continue
        }

        if (-not (Test-LicenseTargetIncluded -licenseTarget $item.Target -target $target)) {
            $item.Status = 'Excluded'
            $item.Message = "Target '$($item.Target)' is not selected by -target; the license was left unchanged."
            Write-Logfile "License '$($item.LicenseName)': $($item.Message)" "INFO"
            continue
        }

        $planItems.Add($item)
    }
}

# Assignment discovery is limited to each license's own subscription by design.
foreach ($item in @($planItems | Where-Object { [string]::IsNullOrWhiteSpace($_.LicenseId) })) {
    $item.Status = 'Failed'
    $item.Message = "The license resource ID could not be determined."
    Write-Logfile "License '$($item.LicenseName)': $($item.Message)" "ERROR"
}

$licenseSubscriptions = @($planItems | Where-Object { $_.Status -eq 'Pending' } | ForEach-Object { $_.LicenseSubscriptionId } | Sort-Object -Unique)
foreach ($subscription in $licenseSubscriptions) {
    $subscriptionItems = @($planItems | Where-Object { $_.Status -eq 'Pending' -and $_.LicenseSubscriptionId -eq $subscription })
    $itemsById = @{}
    foreach ($item in $subscriptionItems) {
        $itemsById[$item.LicenseId.Trim().TrimEnd('/').ToLowerInvariant()] = $item
    }

    Write-Logfile "Querying Azure Resource Graph for servers assigned to $($subscriptionItems.Count) license(s)..." "INFO"
    try {
        $assignments = @(Get-ResourceGraphLicenseAssignment -licenseSubscriptionId $subscription -bearerToken $token)
    } catch {
        $discoveryError = Get-RestErrorMessage -errorRecord $_
        foreach ($item in $subscriptionItems) {
            $item.Status = 'Failed'
            $item.Message = "Assigned servers could not be discovered: $discoveryError"
            Write-Logfile "License '$($item.LicenseName)': $($item.Message)" "ERROR"
        }
        continue
    }

    foreach ($assignment in $assignments) {
        $key = $assignment.LicenseId.Trim().TrimEnd('/').ToLowerInvariant()
        if ($itemsById.ContainsKey($key)) {
            $licenseItem = $itemsById[$key]
            if (-not ($licenseItem.Servers | Where-Object { $_.ProfileId -eq $assignment.ProfileId })) {
                $licenseItem.Servers.Add($assignment)
            }
        }
    }
}

$pendingItems = @($planItems | Where-Object { $_.Status -eq 'Pending' })

if ($pendingItems.Count -gt 0) {
    Write-Logfile "Assignment discovery searches only the subscription that contains each license. Arc servers in other subscriptions that use these licenses are not detected and keep their assignment; the license is still deleted." "WARNING"

    $inventoryPath = if (-not [string]::IsNullOrWhiteSpace($inventoryFilePath)) {
        $inventoryFilePath
    } else {
        Join-Path (Get-Location) "ESULicenseDeletionInventory-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    }

    try {
        $exportedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        # The inventory is a local audit file, so it is written during previews as well.
        ConvertTo-InventoryRow -planItems $pendingItems -exportedAtUtc $exportedAtUtc |
            Export-Csv -Path $inventoryPath -NoTypeInformation -Encoding utf8 -WhatIf:$false -Confirm:$false -ErrorAction Stop
        Write-Logfile "Before-change inventory exported to '$inventoryPath'" "SUCCESS"
    } catch {
        Write-Logfile "Failed to export the before-change inventory to '$inventoryPath': $($_.Exception.Message). No license was changed." "ERROR"
        if (-not [string]::IsNullOrWhiteSpace($logFileName)) { Stop-Transcript | Out-Null }
        exit 1
    }

    Write-Host ""
    Write-Host "Licenses selected for unlink and deletion:"
    $pendingItems |
        Select-Object LicenseName, LicenseResourceGroupName, Target, State, Edition, CoreType, Processors, @{ Name = 'AssignedServers'; Expression = { $_.Servers.Count } } |
        Format-Table -AutoSize | Out-Host
}

$currentItem = 0
foreach ($planItem in $pendingItems) {
    $currentItem++
    $percentComplete = [math]::Round(($currentItem / $pendingItems.Count) * 100, 1)
    Write-Progress -Activity "Unlinking and deleting ESU licenses" -Status "License $currentItem of $($pendingItems.Count) ($percentComplete%)" -PercentComplete $percentComplete

    $serverCount = $planItem.Servers.Count
    $action = if ($serverCount -gt 0) {
        "Unlink $serverCount Arc server(s), then delete ESU license ($($planItem.Target), $($planItem.State))"
    } else {
        "Delete ESU license with no discovered assignment ($($planItem.Target), $($planItem.State))"
    }

    $approved = if ($DryRun) { $true } else { $PSCmdlet.ShouldProcess("$($planItem.LicenseName) (resource group $($planItem.LicenseResourceGroupName))", $action) }
    if (-not $approved -and -not $WhatIfPreference) {
        $planItem.Status = 'Declined'
        $planItem.Message = "Confirmation declined; the license and its assignments were left unchanged."
        Write-Logfile "License '$($planItem.LicenseName)': $($planItem.Message)" "WARNING"
        continue
    }

    Invoke-LicenseDecommission -planItem $planItem -fallbackLocation $location -bearerToken $token -preview:$isPreview
}

Write-Progress -Activity "Unlinking and deleting ESU licenses" -Completed

$deletedCount = @($allItems | Where-Object { $_.Status -eq 'Deleted' }).Count
$wouldDeleteCount = @($allItems | Where-Object { $_.Status -eq 'WouldDelete' }).Count
$excludedCount = @($allItems | Where-Object { $_.Status -eq 'Excluded' }).Count
$declinedCount = @($allItems | Where-Object { $_.Status -eq 'Declined' }).Count
$failedItems = @($allItems | Where-Object { $_.Status -eq 'Failed' })

Write-Host ""
Write-Host "=============================================="
if ($isPreview) {
    Write-Host "DRY RUN - Bulk ESU License Deletion Summary"
} else {
    Write-Host "Bulk ESU License Deletion Summary"
}
Write-Host "=============================================="

if ($allItems.Count -gt 0) {
    $allItems | Select-Object LicenseName, LicenseResourceGroupName, Target, Status, Message | Format-Table -AutoSize -Wrap | Out-Host
}

Write-Logfile "Licenses evaluated: $($allItems.Count)" "INFO"
if ($isPreview) {
    Write-Logfile "Licenses that would be deleted: $wouldDeleteCount" "INFO"
} else {
    Write-Logfile "Licenses deleted: $deletedCount" "SUCCESS"
}
Write-Logfile "Licenses excluded by target or type: $excludedCount" "INFO"
Write-Logfile "Licenses declined at confirmation: $declinedCount" $(if ($declinedCount -gt 0) { "WARNING" } else { "INFO" })
Write-Logfile "Licenses failed: $($failedItems.Count)" $(if ($failedItems.Count -gt 0) { "ERROR" } else { "INFO" })

if ($failedItems.Count -gt 0) {
    Write-Logfile "One or more licenses were not deleted. Review the errors above, correct them, and preview again with -DryRun or -WhatIf." "WARNING"
    $exitCode = 2
} elseif ($isPreview) {
    Write-Logfile "Dry run completed successfully. No actual changes were made." "INFO"
    $exitCode = 0
} else {
    Write-Logfile "Script completed successfully." "SUCCESS"
    $exitCode = 0
}

if (-not [string]::IsNullOrWhiteSpace($logFileName)) { Stop-Transcript | Out-Null }

exit $exitCode

############################
# End of Main script block #
############################
