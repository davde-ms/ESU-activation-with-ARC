<# 
//-----------------------------------------------------------------------

THE SUBJECT SCRIPT IS PROVIDED “AS IS” WITHOUT ANY WARRANTY OF ANY KIND AND SHOULD ONLY BE USED FOR TESTING OR DEMO PURPOSES.
YOU ARE FREE TO REUSE AND/OR MODIFY THE CODE TO FIT YOUR NEEDS

//-----------------------------------------------------------------------

.SYNOPSIS
Creates and manages ESU licenses to be used with Azure ARC in bulk, using an exported CSV from the Azure Portal or a manually created one.

.DESCRIPTION
This script creates, modifies, assigns, and unlinks Azure Arc enabled ESU licenses from CSV input.

The exact target values are Windows Server 2012, Windows Server 2012 R2, and Windows Server 2016. For each row, a nonempty Target cell overrides -target; an empty or absent Target cell uses -target, whose default is Windows Server 2012. Target is resolved independently for every row, so one CSV can mix all three targets.

Target, InvoiceId, and ProgramYear are optional CSV columns. Transition precedence is resolved separately for each field: a nonempty row InvoiceId overrides an explicitly supplied batch -invoiceId, and a nonempty row ProgramYear overrides an explicitly supplied batch -programYear. When an effective invoice exists and no row or batch program year was explicitly supplied, ProgramYear defaults to Year 1. An explicit ProgramYear requires an effective invoice. Year 2 expands to Years 1-2, and Year 3 expands to Years 1-3.

Volume Licensing transition data is supported only for applicable Windows Server 2012 and Windows Server 2012 R2 rows. Windows Server 2016 rejects every effective InvoiceId and every explicitly supplied ProgramYear, whether provided by its row or inherited from batch parameters. Leave both row cells empty and do not supply batch transition parameters for a 2016 row.

The minimum Connected Machine agent version is 1.34 for Windows Server 2012 and Windows Server 2012 R2, and 1.62 for Windows Server 2016. A file containing any row below its target-specific minimum fails complete preflight validation.

The exact WS2012 reserved exception values WS2012 VISUAL STUDIO DEV TEST, WS2012 DISASTER RECOVERY, and WS2012 MULTIPURPOSE are incompatible with Windows Server 2016 rows. These values are rejected for that target; arbitrary tags do not establish Windows Server 2016 eligibility or alter billing.

The script supports two authentication methods: service principal authentication with -tenantId, -appID, and -clientSecret, or a valid Get-AzAccessToken token object supplied with -userToken (alias -token). Complete CSV preflight validation occurs before authentication.

-DryRun validates the CSV, authenticates, performs the existing read-only license-count validation, and displays the resolved operation plan without creating, modifying, assigning, or unlinking resources. -WhatIf also validates, authenticates, performs read-only license-count validation, and previews each ShouldProcess operation without mutation. Declining -Confirm sends no mutation request.

.NOTES
File Name : ManageESULicenses.ps1
Author    : David De Backer, Courtney Vallentyne
Version   : 4.5
Date      : 23-October-2023
Update    : 03-September-2026
Tested on : PowerShell Version 7.6.5
Module    : Azure PowerShell Az.Accounts version 5.5.2
Requires  : Powershell Core version 7.x or later
Product   : Azure ARC

.CHANGELOG
v1.0 - Initial release
v2.0 - Added support for license assignment and unassignment
v3.0 - Added support for ESU license exceptions (Dev/test, AVS hosted, etc.)
v3.2 - Added check for number of licenses to be created based on the CSV file contents vs existing number of licenses in the resource group (to take care of the 800 limit per resource type per resource group)
v4.0 - Added support for program year and invoice ID for ESU licenses (for billing purposes)
v 4.1 - Added support for the new Get-AzAccessToken cmdlet output to obtain the token and modified the script to use the new output format of the cmdlet.
v 4.2 - Added Year 3 support, associated changes.
v4.3 - Clarified invoice ID guidance for applicable Volume Licensing transitions and removed obsolete token-format comments and token console output.
v4.4 - Added full CSV preflight validation, dry-run and WhatIf previews, paginated license counting, reliable failure exits, and operation summaries.
v4.5 - Fixed subscription parameter binding for live bulk operations and added preflight validation for generated license and assignment server names.

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
-licenseNameSuffix "-demo"

This example uses fictitious service principal values. Each nonempty row Target takes precedence over the default Windows Server 2012 batch target, allowing a mixed-target file.

.EXAMPLE-2
$authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
./ManageESULicenses -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-licenseResourceGroupName "rg-demo-arc-esu-licenses" `
-location "EastUS" `
-state "Deactivated" `
-edition "Standard" `
-csvFilePath "C:\Temp\Fictitious ESU Resources.csv" `
-licenseNamePrefix "DEMO-ESU-" `
-userToken $authToken `
-DryRun

This example uses a Microsoft Entra ID token object and performs a non-mutating dry run. Add -WhatIf instead to preview each ShouldProcess operation without mutation.

You can activate the license by changing the -state parameter to 'Activated' and run the same script with the same values again.
For an existing license, you can update supported mutable properties, such as its state or core count where Azure permits. Changes to immutable properties such as edition, core type, or target are rejected by Azure; create a new license with the required values as described in the documentation.
Make sure you read the documentation before using this script.

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
    [string]$logFileName,
    
    [Parameter(Mandatory=$false, HelpMessage="The bearer token obtained from the Azure API by the user. If not provided, the script will require the appID, clientSecret and tenantId parameters.")]
    [Alias("token")]
    [System.Object]$userToken,

    [Parameter(Mandatory=$false, HelpMessage="The invoice number for an applicable Volume Licensing transition entitlement.")]
    [string]$invoiceId,

    [Parameter(Mandatory=$false, HelpMessage="The target Windows Server version for the license.")]
    [ValidateSet("Windows Server 2012", "Windows Server 2012 R2", "Windows Server 2016", ErrorMessage="Value '{0}' is invalid. Try one of: '{1}'")]
    [string]$target = "Windows Server 2012",

    [Parameter(Mandatory=$false, HelpMessage="The program year for ESU licensing. Valid values are 'Year 1', 'Year 2', or 'Year 3'. When specifying Year 2 or Year 3, all previous years will be automatically included as required by Azure.")]
    [ValidateSet("Year 1", "Year 2", "Year 3", ErrorMessage="Value '{0}' is invalid. Try one of: '{1}'")]
    [string]$programYear = "Year 1",

    [Parameter(Mandatory=$false, HelpMessage="Validate the CSV and display the planned operations without creating, modifying, assigning, or unlinking licenses. Read-only Azure validation is still performed.")]
    [Alias("Preview")]
    [switch]$DryRun
)
#####################################
#End of Parameters definition block #
#####################################



##############################
# Variables definition block #
##############################

# Do NOT change those variables as it might break the script. They are meant to be static.
$maxNumberofLicenseObjectsperRG = 800
$global:creator = $MyInvocation.MyCommand.Name
$invoiceIdWasBound = $PSBoundParameters.ContainsKey('invoiceId')
$programYearWasBound = $PSBoundParameters.ContainsKey('programYear')

#########################################
# End of the variables definition block #
#########################################



################################
# Function(s) definition block #
################################

function Get-ProgramYearArray {
    <#
    .SYNOPSIS
    Generates an array of program years including all previous years up to the specified year.
    
    .DESCRIPTION
    Azure requires that when creating ESU licenses for Year 2 or Year 3, all previous years must be included.
    This function takes a program year (Year 1, Year 2, or Year 3) and returns an array containing all years
    from Year 1 up to and including the specified year.
    
    .PARAMETER ProgramYear
    The target program year (Year 1, Year 2, or Year 3)
    
    .EXAMPLE
    Get-ProgramYearArray -ProgramYear "Year 3"
    Returns: @("Year 1", "Year 2", "Year 3")
    #>
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Year 1", "Year 2", "Year 3")]
        [string]$ProgramYear
    )
    
    switch ($ProgramYear) {
        "Year 1" { return @("Year 1") }
        "Year 2" { return @("Year 1", "Year 2") }
        "Year 3" { return @("Year 1", "Year 2", "Year 3") }
    }
}

function ConvertTo-ESULicensePlan {
    param(
        [array]$csvData,
        [string]$state,
        [string]$edition,
        [string]$licenseNamePrefix,
        [string]$licenseNameSuffix,
        [ValidateSet("Windows Server 2012", "Windows Server 2012 R2", "Windows Server 2016")]
        [string]$target = "Windows Server 2012",
        [string]$invoiceId,
        [ValidateSet("Year 1", "Year 2", "Year 3")]
        [string]$programYear = "Year 1",
        [bool]$invoiceIdWasBound = $false,
        [bool]$programYearWasBound = $false
    )

    if ($null -eq $csvData -or $csvData.Count -eq 0) {
        throw "CSV validation failed: the file contains no data rows."
    }

    $requiredColumns = @('Name', 'Cores', 'IsVirtual', 'AgentVersion')
    $availableColumns = @($csvData[0].PSObject.Properties.Name)
    $missingColumns = @($requiredColumns | Where-Object { $_ -notin $availableColumns })
    if ($missingColumns.Count -gt 0) {
        throw "CSV validation failed: missing required column(s): $($missingColumns -join ', ')."
    }

    $errors = [System.Collections.Generic.List[string]]::new()
    $plans = [System.Collections.Generic.List[object]]::new()

    for ($index = 0; $index -lt $csvData.Count; $index++) {
        $row = $csvData[$index]
        $rowNumber = $index + 2
        $rowErrors = [System.Collections.Generic.List[string]]::new()
        $serverName = [string]$row.Name
        $machineType = [string]$row.IsVirtual
        $assignmentValue = [string]$row.AssignESULicense
        $serverResourceGroupName = [string]$row.ServerResourceGroupName
        $licenseName = "$licenseNamePrefix$serverName$licenseNameSuffix"
        $rowTarget = [string]$row.Target
        $effectiveTarget = if ([string]::IsNullOrWhiteSpace($rowTarget)) { $target } else { $rowTarget }
        $supportedTargets = @('Windows Server 2012', 'Windows Server 2012 R2', 'Windows Server 2016')

        if ($effectiveTarget -notin $supportedTargets) {
            $rowErrors.Add("Row $rowNumber, column 'Target': '$effectiveTarget' must be Windows Server 2012, Windows Server 2012 R2, or Windows Server 2016.")
        }

        $rowInvoiceId = [string]$row.InvoiceId
        $effectiveInvoiceId = if (-not [string]::IsNullOrWhiteSpace($rowInvoiceId)) {
            $rowInvoiceId
        } elseif ($invoiceIdWasBound) {
            $invoiceId
        } else {
            $null
        }

        $rowProgramYear = [string]$row.ProgramYear
        $effectiveProgramYear = $null
        $programYearIsExplicit = $false
        if (-not [string]::IsNullOrWhiteSpace($rowProgramYear)) {
            $effectiveProgramYear = $rowProgramYear
            $programYearIsExplicit = $true
        } elseif ($programYearWasBound) {
            $effectiveProgramYear = $programYear
            $programYearIsExplicit = $true
        } elseif (-not [string]::IsNullOrWhiteSpace($effectiveInvoiceId)) {
            $effectiveProgramYear = 'Year 1'
        }

        if ($programYearIsExplicit -and [string]::IsNullOrWhiteSpace($effectiveInvoiceId)) {
            $rowErrors.Add("Row $rowNumber, column 'ProgramYear': an effective invoice is required when a program year is supplied.")
        }

        if ($effectiveTarget -eq 'Windows Server 2016' -and (-not [string]::IsNullOrWhiteSpace($effectiveInvoiceId) -or $programYearIsExplicit)) {
            $transitionColumn = if (-not [string]::IsNullOrWhiteSpace($effectiveInvoiceId)) { 'InvoiceId' } else { 'ProgramYear' }
            $rowErrors.Add("Row $rowNumber, column '$transitionColumn': Volume Licensing transition data isn't supported for Windows Server 2016.")
        }

        $effectiveProgramYears = @()
        if (-not [string]::IsNullOrWhiteSpace($effectiveInvoiceId) -and -not [string]::IsNullOrWhiteSpace($effectiveProgramYear)) {
            if ($effectiveProgramYear -in @('Year 1', 'Year 2', 'Year 3')) {
                $effectiveProgramYears = @(Get-ProgramYearArray -ProgramYear $effectiveProgramYear)
            } else {
                $rowErrors.Add("Row $rowNumber, column 'ProgramYear': '$effectiveProgramYear' must be Year 1, Year 2, or Year 3.")
            }
        }

        if ([string]::IsNullOrWhiteSpace($serverName)) {
            $rowErrors.Add("Row $rowNumber, column 'Name': a non-empty value is required.")
        }

        if (-not [string]::IsNullOrWhiteSpace($licenseName) -and $licenseName -notmatch '^[a-zA-Z0-9-_\.]+$') {
            $rowErrors.Add("Row $rowNumber, column 'Name': final license name '$licenseName' can contain only letters, numbers, hyphens, underscores, and periods.")
        }

        [int]$inputCores = 0
        $coresValid = [int]::TryParse([string]$row.Cores, [ref]$inputCores) -and $inputCores -gt 0
        if (-not $coresValid) {
            $rowErrors.Add("Row $rowNumber, column 'Cores': '$($row.Cores)' must be a positive whole number.")
        }

        $coreType = $null
        [int]$normalizedCores = 0
        switch ($machineType.ToLowerInvariant()) {
            'virtual' {
                $coreType = 'vCore'
                if ($edition -eq 'Datacenter') {
                    $rowErrors.Add("Row $rowNumber, column 'IsVirtual': virtual-core licenses must use Standard edition.")
                }
                if ($coresValid) {
                    $normalizedCores = [math]::Max(8, [math]::Ceiling($inputCores / 2) * 2)
                }
            }
            'physical' {
                $coreType = 'pCore'
                if ($coresValid) {
                    $normalizedCores = [math]::Max(16, [math]::Ceiling($inputCores / 2) * 2)
                }
            }
            default {
                $rowErrors.Add("Row $rowNumber, column 'IsVirtual': '$machineType' must be Virtual or Physical.")
            }
        }

        if ($coresValid -and $normalizedCores -gt 10000) {
            $rowErrors.Add("Row $rowNumber, column 'Cores': the normalized license size of $normalizedCores exceeds the 10,000-core limit.")
        }

        [version]$agentVersion = $null
        if (-not [version]::TryParse([string]$row.AgentVersion, [ref]$agentVersion)) {
            $rowErrors.Add("Row $rowNumber, column 'AgentVersion': '$($row.AgentVersion)' is not a valid version.")
        } else {
            $minimumAgentVersion = if ($effectiveTarget -eq 'Windows Server 2016') { [version]'1.62' } else { [version]'1.34' }
            if ($agentVersion -lt $minimumAgentVersion) {
                $rowErrors.Add("Row $rowNumber, column 'AgentVersion': version $agentVersion is below the minimum $minimumAgentVersion required for $effectiveTarget.")
            }
        }

        $esuException = [string]$row.ESUException
        $reserved2012Exceptions = @(
            'WS2012 VISUAL STUDIO DEV TEST',
            'WS2012 DISASTER RECOVERY',
            'WS2012 MULTIPURPOSE'
        )
        if ($effectiveTarget -eq 'Windows Server 2016' -and $esuException -in $reserved2012Exceptions) {
            $rowErrors.Add("Row $rowNumber, column 'ESUException': '$esuException' is reserved for Windows Server 2012. Tags don't establish Windows Server 2016 eligibility or alter billing.")
        }

        $assignmentAction = switch ($assignmentValue.ToLowerInvariant()) {
            'true' { 'Assign' }
            'false' { 'Unlink' }
            '' { 'None' }
            default {
                $rowErrors.Add("Row $rowNumber, column 'AssignESULicense': '$assignmentValue' must be True, False, or empty.")
                'Invalid'
            }
        }

        if ($assignmentAction -in @('Assign', 'Unlink') -and [string]::IsNullOrWhiteSpace($serverResourceGroupName)) {
            $rowErrors.Add("Row $rowNumber, column 'ServerResourceGroupName': a value is required when AssignESULicense is True or False.")
        }

        if ($assignmentAction -in @('Assign', 'Unlink') -and $serverName -notmatch '^[a-zA-Z0-9-_\.]{1,54}$') {
            $rowErrors.Add("Row $rowNumber, column 'Name': Azure Arc server names used for assignment or unlinking must be 1-54 characters and contain only letters, numbers, hyphens, underscores, and periods.")
        }

        if ($rowErrors.Count -gt 0) {
            foreach ($rowError in $rowErrors) {
                $errors.Add($rowError)
            }
            continue
        }

        $plans.Add([pscustomobject]@{
            RowNumber = $rowNumber
            ServerName = $serverName
            LicenseName = $licenseName
            State = $state
            Edition = $edition
            InputCores = $inputCores
            CoreCount = $normalizedCores
            CoreType = $coreType
            AgentVersion = $agentVersion
            Target = $effectiveTarget
            MinimumAgentVersion = $minimumAgentVersion
            InvoiceId = $effectiveInvoiceId
            ProgramYears = $effectiveProgramYears
            TransitionMode = if ([string]::IsNullOrWhiteSpace($effectiveInvoiceId)) { 'None' } else { 'VolumeLicense' }
            CreationAction = 'CreateOrModify'
            AssignmentAction = $assignmentAction
            ServerResourceGroupName = $serverResourceGroupName
            ESUException = $esuException
        })
    }

    $duplicateLicenseNames = @($plans | Group-Object -Property LicenseName | Where-Object Count -gt 1)
    foreach ($duplicate in $duplicateLicenseNames) {
        $errors.Add("CSV rows resolve to duplicate license name '$($duplicate.Name)'. Use unique names or adjust the prefix and suffix.")
    }

    if ($errors.Count -gt 0) {
        throw "CSV validation failed:`n - $($errors -join "`n - ")"
    }

    return $plans.ToArray()
}

function AssignESULicense {

    param (
        [string]$subscriptionId,
        [string]$token,
        [string]$licenseResourceGroupName,
        [string]$licenseName,
        [string]$ARCServerName,
        [string]$serverResourceGroupName,
        [string]$location,
        [switch]$unassign
    )

    $apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$serverResourceGroupName/providers/Microsoft.HybridCompute/machines/$ARCServerName/licenseProfiles/default`?api-version=2025-02-19-preview"
    $licenseID = "/subscriptions/$subscriptionId/resourceGroups/$licenseResourceGroupName/providers/Microsoft.HybridCompute/licenses/$licenseName" 
    $method = "PUT"

    # Sets the headers for the request
    $headers = @{
        "Authorization" = "Bearer $token"
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
    $requestBodyJson = $requestBody | ConvertTo-Json -Depth 8

    # Sends the PUT request to update the license
    $null = Invoke-RestMethod -Uri $apiEndpoint -Method $method -Headers $headers -Body $requestBodyJson

    Write-Host ""
    return $true
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
            $accessToken = ((Invoke-WebRequest -Method Post -Uri $oAuthEndpoint -ContentType "application/x-www-form-urlencoded" -Body $authbody).Content | ConvertFrom-Json).access_token
            return $accessToken
    }
    
    catch { 
        Write-Error "Error obtaining Bearer token: $_"
        return $null
     }    
}

function CreateESULicense {
    param (
        [string]$subscriptionId,
        [string]$token,
        [string]$location,
        [string]$licenseResourceGroupName,
        [string]$licenseName,
        [string]$state,
        [string]$edition,
        [string]$coreType,
        [int]$coreCount,
        [string]$ESULicenseException,
        [ValidateSet("Windows Server 2012", "Windows Server 2012 R2", "Windows Server 2016")]
        [string]$target = "Windows Server 2012",
        [string]$invoiceId,
        [array]$programYears,
        [ValidateSet("None", "VolumeLicense")]
        [string]$transitionMode = "None"
    )

    $licenseApiVersion = "2026-06-16-preview"
    $apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$licenseResourceGroupName/providers/Microsoft.HybridCompute/licenses/$licenseName`?api-version=$licenseApiVersion"

# Sets the headers for the request
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
}

$licenseDetails = @{
    state = $state
    target = $target
    edition = $edition
    Type = $coreType
    Processors = $coreCount
}

if ($transitionMode -eq "VolumeLicense") {
    $validProgramYears = @("Year 1", "Year 2", "Year 3")
    $invalidProgramYears = @($programYears | Where-Object { $_ -notin $validProgramYears })
    if ($target -eq "Windows Server 2016" -or [string]::IsNullOrWhiteSpace($invoiceId) -or $programYears.Count -eq 0 -or $invalidProgramYears.Count -gt 0) {
        throw "Invalid Volume Licensing transition data for target '$target'."
    }

    $licenseDetails["volumeLicenseDetails"] = @($programYears | ForEach-Object {
        @{
            programYear = $_
            invoiceId = $invoiceId
        }
    })
}

# Defines the request body as a PowerShell hashtable
$requestBody = @{
    location = $location
    properties = @{
        licenseType = "ESU"
        licenseDetails = $licenseDetails
    }
    tags = @{
        CreatedBy = "$global:creator"
    }
}

if ($ESULicenseException -ne $false) {$requestBody['tags']['ESU Usage'] = $ESULicenseException}

# Converts the request body to JSON
$requestBodyJson = $requestBody | ConvertTo-Json -Depth 8 

Write-Verbose $requestBodyJson

# Sends the PUT request to update the license
$null = Invoke-RestMethod -Uri $apiEndpoint -Method PUT -Headers $headers -Body $requestBodyJson

Write-Host "Creating or modifying $licenseName license for $target with $coreCount $coreType (transition: $transitionMode)"
Write-Host ""
return $true

}

function CountResources {
    param (
        [string]$token,
        [string]$licenseResourceGroupName,
        [array]$licensePlans
    )
    $resourceType = "Microsoft.HybridCompute/licenses"
    $apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$licenseResourceGroupName/resources?api-version=2022-01-01"
    
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }

    $resources = [System.Collections.Generic.List[object]]::new()
    $nextLink = $apiEndpoint
    while (-not [string]::IsNullOrWhiteSpace($nextLink)) {
        $page = Invoke-RestMethod -Uri $nextLink -Method GET -Headers $headers
        foreach ($resource in @($page.value)) {
            $resources.Add($resource)
        }
        $nextLink = [string]$page.nextLink
    }

    $existingLicenses = @($resources | Where-Object { $_.type -eq $resourceType })
    $existingESULicensesCount = $existingLicenses.Count
    $existingNames = @($existingLicenses | ForEach-Object { $_.name })
    $requestedNames = @($licensePlans | Where-Object CreationAction -eq 'CreateOrModify' | ForEach-Object { $_.LicenseName } | Select-Object -Unique)
    $newESULicensesToCreate = @($requestedNames | Where-Object { $_ -notin $existingNames }).Count
    return $existingESULicensesCount, $newESULicensesToCreate

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
Clear-Host

try {
    $data = @(Import-Csv -Path $csvFilePath -ErrorAction Stop)
    $licensePlans = @(ConvertTo-ESULicensePlan -csvData $data -state $state -edition $edition -licenseNamePrefix $licenseNamePrefix -licenseNameSuffix $licenseNameSuffix -target $target -invoiceId $invoiceId -programYear $programYear -invoiceIdWasBound $invoiceIdWasBound -programYearWasBound $programYearWasBound)
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

Write-Host "Validated CSV rows: $($licensePlans.Count)" -ForegroundColor Green

# Check if the token is still valid
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
    Write-Host "You need to provide either the tenant, appID and clientSecret parameters or a valid authentication token object.`nExiting." -ForegroundColor Red
    exit 1
}

#Check the number of licenses already created in the resource group
try {
    $result = CountResources -token $token -licenseResourceGroupName $licenseResourceGroupName -licensePlans $licensePlans
} catch {
    Write-Host "Failed to read existing ESU licenses: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$existingESULicensesCount = $result[0]
$newESULicensesToCreate = $result[1]

Write-Host "Number of existing licenses in $licenseResourceGroupName : $existingESULicensesCount"
Write-Host "Number of new licenses to create in $licenseResourceGroupName : $newESULicensesToCreate"

if (($existingESULicensesCount + $newESULicensesToCreate) -gt $maxNumberofLicenseObjectsperRG) {
    Write-Host "The number of licenses to create ($newESULicensesToCreate) plus the existing ones ($existingESULicensesCount) exceeds the limit of $maxNumberofLicenseObjectsperRG objects per resource group."
    Write-Host "Please choose another resource group to store the licenses to be created and try again."
    exit 1
}


Write-Host ""
Write-Host "==========================================="
Write-Host "Starting ESU license creation from CSV file"
Write-Host "==========================================="

If (![string]::IsNullOrWhiteSpace($logFileName)) {Start-Transcript -Path $logFileName}

$summary = [ordered]@{
    TotalRows = $licensePlans.Count
    LicensesCreatedOrModified = 0
    AssignmentsCompleted = 0
    UnlinksCompleted = 0
    SkippedAgentVersion = 0
    PreviewedOperations = 0
    Failures = 0
}

Write-Host ""
Write-Host "Validated operation plan"
$licensePlans | Select-Object RowNumber, ServerName, LicenseName, State, Edition, Target, TransitionMode, MinimumAgentVersion, CoreType, CoreCount, AgentVersion, CreationAction, AssignmentAction | Format-Table -AutoSize | Out-Host

if ($DryRun) {
    $summary.PreviewedOperations = $licensePlans.Count + @($licensePlans | Where-Object AssignmentAction -ne 'None').Count
} else {
    foreach ($planItem in $licensePlans) {
        $licenseReady = $false
        if ($PSCmdlet.ShouldProcess($planItem.LicenseName, "Create or modify $($planItem.State) $($planItem.Edition) ESU license for $($planItem.Target) with $($planItem.CoreCount) $($planItem.CoreType) (transition: $($planItem.TransitionMode))")) {
            try {
                $exceptionValue = if ([string]::IsNullOrWhiteSpace($planItem.ESUException)) { $false } else { $planItem.ESUException }
            CreateESULicense -subscriptionId $subscriptionId -token $token -location $location -licenseResourceGroupName $licenseResourceGroupName -licenseName $planItem.LicenseName -state $planItem.State -edition $planItem.Edition -CoreType $planItem.CoreType -CoreCount $planItem.CoreCount -ESULicenseException $exceptionValue -target $planItem.Target -invoiceId $planItem.InvoiceId -programYears $planItem.ProgramYears -transitionMode $planItem.TransitionMode | Out-Null
                $summary.LicensesCreatedOrModified++
                $licenseReady = $true
            } catch {
                Write-Host "Row $($planItem.RowNumber): failed to create or modify license '$($planItem.LicenseName)': $($_.Exception.Message)" -ForegroundColor Red
                $summary.Failures++
                continue
            }
        } else {
            $summary.PreviewedOperations++
            if ($WhatIfPreference) {
                $licenseReady = $true
            }
        }

        if (-not $licenseReady -or $planItem.AssignmentAction -eq 'None') {
            continue
        }

        $assignmentVerb = if ($planItem.AssignmentAction -eq 'Assign') { 'Assign' } else { 'Unlink' }
        if ($PSCmdlet.ShouldProcess($planItem.ServerName, "$assignmentVerb ESU license '$($planItem.LicenseName)'")) {
            $params = @{
                subscriptionId = $subscriptionId
                token = $token
                licenseResourceGroupName = $licenseResourceGroupName
                licenseName = $planItem.LicenseName
                serverResourceGroupName = $planItem.ServerResourceGroupName
                ARCServerName = $planItem.ServerName
                location = $location
                unassign = $planItem.AssignmentAction -eq 'Unlink'
            }

            try {
                AssignESULicense @params | Out-Null
                if ($planItem.AssignmentAction -eq 'Assign') {
                    $summary.AssignmentsCompleted++
                } else {
                    $summary.UnlinksCompleted++
                }
            } catch {
                Write-Host "Row $($planItem.RowNumber): failed to $($assignmentVerb.ToLowerInvariant()) license '$($planItem.LicenseName)' for '$($planItem.ServerName)': $($_.Exception.Message)" -ForegroundColor Red
                $summary.Failures++
            }
        } else {
            $summary.PreviewedOperations++
        }
    }
}

If (![string]::IsNullOrWhiteSpace($logFileName)) {Stop-Transcript}

Write-Host ""
Write-Host "ESU License Operation Summary"
Write-Host "Total validated rows: $($summary.TotalRows)"
Write-Host "Licenses created or modified: $($summary.LicensesCreatedOrModified)"
Write-Host "Assignments completed: $($summary.AssignmentsCompleted)"
Write-Host "Unlinks completed: $($summary.UnlinksCompleted)"
Write-Host "Skipped for agent version: $($summary.SkippedAgentVersion)"
Write-Host "Previewed or declined operations: $($summary.PreviewedOperations)"
Write-Host "Failures: $($summary.Failures)"

if ($summary.Failures -gt 0) {
    exit 1
}

exit 0



############################
# End of Main script block #
############################





