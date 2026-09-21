<#
.SYNOPSIS
Tests Azure Arc prerequisites for SQL Server 2014 and SQL Server 2016 ESUs.

.DESCRIPTION
Performs a read-only assessment of an Arc-enabled Windows machine, the
WindowsAgent.SqlServer extension, provider registration, and correlated Arc SQL
inventory. All CSV input is validated before authentication. No Azure resource is
created, updated, registered, or deleted.

.EXAMPLE
./Scripts/sql/TestSQLServerArcESUPrerequisites.ps1 -subscriptionId '00000000-0000-0000-0000-000000000001' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01' -userToken $token

.EXAMPLE
./Scripts/sql/TestSQLServerArcESUPrerequisites.ps1 -subscriptionId '00000000-0000-0000-0000-000000000001' -csvFilePath '.\machines.csv' -userToken $token -exportCsvPath '.\prerequisites.csv'
#>

[CmdletBinding(DefaultParameterSetName = 'SingleMachine')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [Alias('sub')]
    [string]$subscriptionId,

    [Parameter(Mandatory = $true, ParameterSetName = 'SingleMachine')]
    [ValidatePattern('^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$')]
    [Alias('srg')]
    [string]$serverResourceGroupName,

    [Parameter(Mandatory = $true, ParameterSetName = 'SingleMachine')]
    [ValidatePattern('^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,54}$')]
    [Alias('server')]
    [string]$ARCServerName,

    [Parameter(Mandatory = $true, ParameterSetName = 'Csv')]
    [ValidateScript({
        if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) { throw "The CSV file does not exist: $_" }
        if ([System.IO.Path]::GetExtension($_) -ine '.csv') { throw "The file must have a .csv extension: $_" }
        $true
    })]
    [Alias('csv')]
    [string]$csvFilePath,

    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$tenantId,

    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$appID,

    [Parameter()]
    [Alias('s', 'secret', 'sec')]
    [string]$clientSecret,

    [Parameter()]
    [Alias('token')]
    [object]$userToken,

    [Parameter()]
    [Alias('export')]
    [string]$exportCsvPath
)

$script:CONFIG = @{
    AzureResourceUrl = 'https://management.azure.com/'
    LoginEndpoint = 'https://login.microsoftonline.com'
    MachineApiVersion = '2026-07-15'
    ExtensionApiVersion = '2026-07-15'
    SqlInstanceApiVersion = '2026-01-01'
    ProviderApiVersion = '2021-04-01'
    SqlExtensionName = 'WindowsAgent.SqlServer'
    SupportedExtensionVersions = @('1.1.3518.465')
}

function Get-AzureADBearerToken {
    param(
        [Parameter(Mandatory = $true)][string]$appID,
        [Parameter(Mandatory = $true)][string]$clientSecret,
        [Parameter(Mandatory = $true)][string]$tenantId,
        [int]$retryCount = 3,
        [int]$retryDelaySeconds = 5
    )

    $endpoint = "$($script:CONFIG.LoginEndpoint)/$tenantId/oauth2/token"
    $body = @{
        grant_type = 'client_credentials'
        client_id = $appID
        client_secret = $clientSecret
        resource = $script:CONFIG.AzureResourceUrl
    }

    for ($attempt = 1; $attempt -le $retryCount; $attempt++) {
        try {
            $response = Invoke-WebRequest -Method Post -Uri $endpoint -ContentType 'application/x-www-form-urlencoded' -Body $body -ErrorAction Stop
            $accessToken = ($response.Content | ConvertFrom-Json).access_token
            if ([string]::IsNullOrWhiteSpace($accessToken)) { throw 'Authentication response did not contain an access token.' }
            return $accessToken
        }
        catch {
            if ($attempt -eq $retryCount) { return $null }
            Start-Sleep -Seconds $retryDelaySeconds
        }
    }
}

function ConvertTo-PlainTextToken {
    param([Parameter(Mandatory = $true)][object]$TokenObject)

    if ($TokenObject.PSObject.Properties['ExpiresOn'] -and $TokenObject.ExpiresOn -le (Get-Date)) {
        throw 'The provided user token has expired.'
    }
    if (-not $TokenObject.PSObject.Properties['Token']) { throw 'The provided user token object has no Token property.' }
    if ($TokenObject.Token -is [securestring]) {
        return ConvertFrom-SecureString -SecureString $TokenObject.Token -AsPlainText
    }
    if ([string]::IsNullOrWhiteSpace([string]$TokenObject.Token)) { throw 'The provided user token is empty.' }
    return [string]$TokenObject.Token
}

function Get-ObjectValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Paths
    )

    foreach ($path in $Paths) {
        $value = $InputObject
        foreach ($segment in $path.Split('.')) {
            if ($null -eq $value -or -not $value.PSObject.Properties[$segment]) { $value = $null; break }
            $value = $value.$segment
        }
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { return $value }
    }
    return $null
}

function ConvertTo-NormalizedResourceId {
    param([AllowNull()][string]$ResourceId)
    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return '' }
    return $ResourceId.Trim().TrimEnd('/').ToLowerInvariant()
}

function ConvertTo-BooleanValue {
    param([AllowNull()][object]$Value)
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        if ($Value.Equals('true', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($Value.Equals('false', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $null
}

function Test-NotFoundError {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    if ($ErrorRecord.Exception.Response -and [int]$ErrorRecord.Exception.Response.StatusCode -eq 404) { return $true }
    return $ErrorRecord.Exception.Message -match '(^|\D)404(\D|$)|NotFound|not found'
}

function ConvertTo-PrerequisitePlan {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$DefaultSubscriptionId
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $plans = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $requiredHeaders = @('SubscriptionId', 'ServerResourceGroupName', 'ARCServerName')

    if ($Rows.Count -eq 0) { throw 'The CSV file contains no data rows.' }
    foreach ($header in $requiredHeaders) {
        if (-not $Rows[0].PSObject.Properties[$header]) { $errors.Add("Missing required CSV column '$header'.") }
    }
    if ($errors.Count -gt 0) { throw ($errors -join [Environment]::NewLine) }

    for ($index = 0; $index -lt $Rows.Count; $index++) {
        $row = $Rows[$index]
        $rowNumber = $index + 2
        $rowSubscription = if ([string]::IsNullOrWhiteSpace([string]$row.SubscriptionId)) { $DefaultSubscriptionId } else { [string]$row.SubscriptionId }
        $resourceGroup = [string]$row.ServerResourceGroupName
        $machineName = [string]$row.ARCServerName

        if ($rowSubscription -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { $errors.Add("Row $rowNumber has an invalid SubscriptionId.") }
        if ($resourceGroup -notmatch '^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$') { $errors.Add("Row $rowNumber has an invalid ServerResourceGroupName.") }
        if ($machineName -notmatch '^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,54}$') { $errors.Add("Row $rowNumber has an invalid ARCServerName.") }

        $key = "$rowSubscription/$resourceGroup/$machineName".ToLowerInvariant()
        if ($seen.ContainsKey($key)) { $errors.Add("Row $rowNumber duplicates machine '$machineName' in subscription '$rowSubscription' and resource group '$resourceGroup'.") }
        else { $seen[$key] = $true }

        $plans.Add([pscustomobject]@{
            SubscriptionId = $rowSubscription
            ResourceGroupName = $resourceGroup
            MachineName = $machineName
        })
    }

    if ($errors.Count -gt 0) { throw ($errors -join [Environment]::NewLine) }
    return @($plans)
}

function Get-ProviderInformation {
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][string]$ProviderNamespace,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )
    $uri = "$($script:CONFIG.AzureResourceUrl)subscriptions/$SubscriptionId/providers/$ProviderNamespace`?api-version=$($script:CONFIG.ProviderApiVersion)"
    return Invoke-RestMethod -Uri $uri -Method GET -Headers $Headers -ErrorAction Stop
}

function Test-ArmNextLink {
    param([Parameter(Mandatory = $true)][string]$NextLink)

    $uri = $null
    if (-not [uri]::TryCreate($NextLink, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne [Uri]::UriSchemeHttps -or
        $uri.Host -ine 'management.azure.com') {
        throw 'ARM pagination nextLink must use HTTPS and the management.azure.com host.'
    }
}

function Get-AllSqlServerInstances {
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )
    $instances = [System.Collections.Generic.List[object]]::new()
    $nextLink = "$($script:CONFIG.AzureResourceUrl)subscriptions/$SubscriptionId/providers/Microsoft.AzureArcData/sqlServerInstances?api-version=$($script:CONFIG.SqlInstanceApiVersion)"
    while (-not [string]::IsNullOrWhiteSpace($nextLink)) {
        $page = Invoke-RestMethod -Uri $nextLink -Method GET -Headers $Headers -ErrorAction Stop
        foreach ($instance in @($page.value)) { $instances.Add($instance) }
        $nextLink = [string]$page.nextLink
        if (-not [string]::IsNullOrWhiteSpace($nextLink)) { Test-ArmNextLink -NextLink $nextLink }
    }
    return @($instances)
}

function Get-SqlInstanceClassification {
    param([Parameter(Mandatory = $true)][object]$Instance)

    $version = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.version', 'properties.currentVersion', 'properties.productVersion'))
    $edition = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.edition', 'properties.currentEdition'))
    $eligibleVersion = if ($version -match '(?i)SQL\s*Server\s*2014|^12(\.|$)') { 'SQL Server 2014' } elseif ($version -match '(?i)SQL\s*Server\s*2016|^13(\.|$)') { 'SQL Server 2016' } else { $null }
    $eligibleEdition = $edition -match '(?i)\b(Standard|Enterprise)\b'
    $eligibility = if (-not $eligibleVersion) { 'Ineligible' } elseif ($eligibleEdition) { 'Eligible' } elseif ($edition -match '(?i)\bDeveloper\b') { 'ExternalConfirmationRequired' } else { 'Ineligible' }
    $reason = switch ($eligibility) {
        'Eligible' { 'Supported SQL Server version and production edition.' }
        'ExternalConfirmationRequired' { 'Developer edition requires qualifying nonproduction coverage that ARM cannot verify.' }
        default { if (-not $eligibleVersion) { 'Only SQL Server 2014 and SQL Server 2016 are eligible.' } else { "Edition '$edition' does not establish eligible production coverage." } }
    }

    return [pscustomobject]@{
        Name = [string]$Instance.name
        ResourceId = [string]$Instance.id
        Version = $version
        EligibleVersion = $eligibleVersion
        Edition = $edition
        Eligibility = $eligibility
        Reason = $reason
        ServiceType = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.serviceType'))
        Status = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.status'))
        HostType = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.hostType', 'properties.hostingType'))
        DetectedCores = Get-ObjectValue -InputObject $Instance -Paths @('properties.vCore', 'properties.vCores', 'properties.coreCount', 'properties.cores', 'properties.hostResources.logicalCores')
        InventoryTimestamp = Get-ObjectValue -InputObject $Instance -Paths @('properties.lastInventoryUploadTime')
        UsageTimestamp = Get-ObjectValue -InputObject $Instance -Paths @('properties.lastUsageUploadTime')
        PatchLevel = Get-ObjectValue -InputObject $Instance -Paths @('properties.patchLevel', 'properties.currentVersion')
    }
}

function Get-Freshness {
    param(
        [object[]]$Instances,
        [ValidateSet('InventoryTimestamp', 'UsageTimestamp')][string]$PropertyName,
        [datetime]$Now = [datetime]::UtcNow
    )
    if ($Instances.Count -eq 0) { return 'Unknown' }
    foreach ($instance in $Instances) {
        $value = $instance.$PropertyName
        if ($null -eq $value) { return 'Unknown' }
        $timestamp = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$value, [ref]$timestamp)) { return 'Unknown' }
        if ($timestamp.ToUniversalTime() -lt $Now.ToUniversalTime().AddHours(-24)) { return 'Stale' }
    }
    return 'Fresh'
}

function Get-PrerequisiteResult {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $machineId = "/subscriptions/$($Plan.SubscriptionId)/resourceGroups/$($Plan.ResourceGroupName)/providers/Microsoft.HybridCompute/machines/$($Plan.MachineName)"
    $blocking = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $external = @(
        'NotVerifiableByARM: outbound TCP 443 access to Azure Arc and the regional Arc data service endpoint.',
        'NotVerifiableByARM: access to aka.ms and *.web.core.windows.net.',
        'NotVerifiableByARM: local Windows and SQL permissions, including NT AUTHORITY\SYSTEM CONNECT SQL.',
        'NotVerifiableByARM: 64-bit SQL architecture when inventory omits architecture.',
        'NotVerifiableByARM: customer entitlement, prior-year ESU coverage, Software Assurance/subscription, and nonproduction coverage.',
        'NotVerifiableByARM: complete HA/DR licensing compliance beyond extension-reported state.'
    )
    $machine = $null
    $extension = $null
    $instances = @()
    $hybridRegistered = $false
    $arcDataRegistered = $false
    $regionSupported = $null

    try {
        $hybridProvider = Get-ProviderInformation -SubscriptionId $Plan.SubscriptionId -ProviderNamespace 'Microsoft.HybridCompute' -Headers $Headers
        $arcDataProvider = Get-ProviderInformation -SubscriptionId $Plan.SubscriptionId -ProviderNamespace 'Microsoft.AzureArcData' -Headers $Headers
        $hybridRegistered = [string]$hybridProvider.registrationState -eq 'Registered'
        $arcDataRegistered = [string]$arcDataProvider.registrationState -eq 'Registered'
        if (-not $hybridRegistered) { $blocking.Add('Microsoft.HybridCompute is not registered. Registration requires a separate privileged action.') }
        if (-not $arcDataRegistered) { $blocking.Add('Microsoft.AzureArcData is not registered. Registration requires a separate privileged action.') }

        $machineUri = "$($script:CONFIG.AzureResourceUrl)$($machineId.TrimStart('/'))?api-version=$($script:CONFIG.MachineApiVersion)"
        try { $machine = Invoke-RestMethod -Uri $machineUri -Method GET -Headers $Headers -ErrorAction Stop }
        catch {
            if (Test-NotFoundError -ErrorRecord $_) { $blocking.Add('Arc machine was not found.') }
            else { throw }
        }

        if ($machine) {
            $connectionStatus = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.status', 'properties.connectionStatus'))
            $agentMode = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.agentConfiguration.mode'))
            $operatingSystem = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.osName', 'properties.osType'))
            $location = [string]$machine.location
            $cloudProvider = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.detectedProperties.cloudProvider', 'properties.cloudMetadataProvider'))
            if ($connectionStatus -ine 'Connected') { $blocking.Add("Arc machine connection status is '$connectionStatus', not 'Connected'.") }
            if ($agentMode -ine 'Full') { $blocking.Add("Arc agent mode is '$agentMode', not 'Full'.") }
            if ($operatingSystem -notmatch '(?i)Windows') { $blocking.Add("Operating system '$operatingSystem' is not Windows.") }
            if ($cloudProvider -ieq 'Azure') { $blocking.Add('Native Azure virtual machines must use the SQL IaaS Agent extension, not this Arc workflow.') }
            if ([string]::IsNullOrWhiteSpace($location)) {
                $blocking.Add('Arc machine response has no location.')
            }
            else {
                $sqlResourceType = @($arcDataProvider.resourceTypes | Where-Object { $_.resourceType -ieq 'sqlServerInstances' }) | Select-Object -First 1
                if ($null -eq $sqlResourceType -or @($sqlResourceType.locations).Count -eq 0) {
                    $blocking.Add("Support for machine location '$location' is indeterminate because Microsoft.AzureArcData did not return sqlServerInstances locations.")
                }
                else {
                    $normalizedLocation = ($location -replace '\s', '').ToLowerInvariant()
                    $supportedLocations = @($sqlResourceType.locations | ForEach-Object { ([string]$_ -replace '\s', '').ToLowerInvariant() })
                    $regionSupported = $normalizedLocation -in $supportedLocations
                    if (-not $regionSupported) { $blocking.Add("Machine location '$location' is not listed for Microsoft.AzureArcData/sqlServerInstances.") }
                }
            }

            $extensionUri = "$($script:CONFIG.AzureResourceUrl)$($machineId.TrimStart('/'))/extensions/$($script:CONFIG.SqlExtensionName)?api-version=$($script:CONFIG.ExtensionApiVersion)"
            try { $extension = Invoke-RestMethod -Uri $extensionUri -Method GET -Headers $Headers -ErrorAction Stop }
            catch {
                if (-not (Test-NotFoundError -ErrorRecord $_)) { throw }
            }

            $instances = @(Get-AllSqlServerInstances -SubscriptionId $Plan.SubscriptionId -Headers $Headers | Where-Object {
                (ConvertTo-NormalizedResourceId (Get-ObjectValue -InputObject $_ -Paths @('properties.containerResourceId'))) -eq (ConvertTo-NormalizedResourceId $machineId)
            } | ForEach-Object { Get-SqlInstanceClassification -Instance $_ })
        }
    }
    catch {
        $blocking.Add("Assessment failed: $($_.Exception.Message)")
    }

    $extensionState = if (-not $machine) { 'NotAssessed' } elseif (-not $extension) { 'Absent' } else { [string](Get-ObjectValue -InputObject $extension -Paths @('properties.provisioningState')) }
    $extensionVersion = if ($extension) { [string](Get-ObjectValue -InputObject $extension -Paths @('properties.typeHandlerVersion')) } else { $null }
    $publisher = if ($extension) { [string](Get-ObjectValue -InputObject $extension -Paths @('properties.publisher')) } else { $null }
    $extensionType = if ($extension) { [string](Get-ObjectValue -InputObject $extension -Paths @('properties.type')) } else { $null }
    $automaticUpgrade = if ($extension) { ConvertTo-BooleanValue (Get-ObjectValue -InputObject $extension -Paths @('properties.enableAutomaticUpgrade', 'properties.autoUpgradeMinorVersion')) } else { $null }
    $extensionSupported = if (-not $extension) { $false } elseif ($publisher -ne 'Microsoft.AzureData' -or $extensionType -ne 'WindowsAgent.SqlServer') { $false } elseif ($extensionState -ne 'Succeeded') { $false } elseif ($extensionVersion -notin $script:CONFIG.SupportedExtensionVersions) { $false } else { $true }
    $settings = if ($extension) { Get-ObjectValue -InputObject $extension -Paths @('properties.settings') } else { $null }
    $licenseType = [string](Get-ObjectValue -InputObject $settings -Paths @('LicenseType'))
    $sqlManagementEnabled = ConvertTo-BooleanValue (Get-ObjectValue -InputObject $settings -Paths @('SqlManagement.IsEnabled'))
    $esuEnabled = ConvertTo-BooleanValue (Get-ObjectValue -InputObject $settings -Paths @('enableExtendedSecurityUpdates'))
    $esuTimestamp = Get-ObjectValue -InputObject $settings -Paths @('esuLastUpdatedTimestamp')

    if ($extension) {
        if ($publisher -ne 'Microsoft.AzureData' -or $extensionType -ne 'WindowsAgent.SqlServer') { $blocking.Add('The SQL extension has an unexpected publisher or type.') }
        if ($extensionState -ne 'Succeeded') { $blocking.Add("SQL extension provisioning state is '$extensionState'.") }
        if ([string]::IsNullOrWhiteSpace($extensionVersion)) { $blocking.Add('SQL extension version is missing and cannot be evaluated against the supported 12-month release baseline.') }
        elseif ($extensionVersion -notin $script:CONFIG.SupportedExtensionVersions) { $blocking.Add("SQL extension version '$extensionVersion' is not in the implementation-day 12-month supported release baseline ($($script:CONFIG.SupportedExtensionVersions -join ', ')).") }
        if (-not $automaticUpgrade) { $warnings.Add('Automatic extension upgrade is not enabled; verify that the installed version was released within the last 12 months.') }
        if (-not $sqlManagementEnabled) { $blocking.Add('SqlManagement.IsEnabled is not true.') }
        if ($licenseType -notin @('Paid', 'PAYG')) { $blocking.Add("LicenseType '$licenseType' is not eligible for Arc-enabled SQL Server ESUs.") }
    }
    else {
        $warnings.Add('WindowsAgent.SqlServer is absent; SQL inventory may be unavailable until the extension is installed separately.')
    }

    $eligibleInstances = @($instances | Where-Object Eligibility -eq 'Eligible')
    $ineligibleInstances = @($instances | Where-Object Eligibility -ne 'Eligible')
    if ($extension -and $eligibleInstances.Count -eq 0) { $blocking.Add('No eligible SQL Server 2014 or SQL Server 2016 Standard/Enterprise instance was discovered.') }
    if ($instances | Where-Object Eligibility -eq 'ExternalConfirmationRequired') { $warnings.Add('At least one Developer edition instance requires external nonproduction coverage confirmation.') }
    $eligibleVersions = @($eligibleInstances | ForEach-Object EligibleVersion | Select-Object -Unique)
    $mixedVersions = $eligibleVersions.Count -gt 1
    if ($mixedVersions) { $warnings.Add('Both SQL Server 2014 and SQL Server 2016 are present; each eligible version can produce a separate ESU meter.') }

    $inventoryFreshness = Get-Freshness -Instances $instances -PropertyName InventoryTimestamp
    $usageFreshness = Get-Freshness -Instances $instances -PropertyName UsageTimestamp
    if ($inventoryFreshness -ne 'Fresh') { $warnings.Add("Inventory timestamp classification is $inventoryFreshness; eligibility is uncertain, but freshness alone is warning-only.") }
    if ($usageFreshness -ne 'Fresh') { $warnings.Add("Usage timestamp classification is $usageFreshness; eligibility is uncertain, but freshness alone is warning-only.") }

    $hostType = [string](($instances | ForEach-Object HostType | Where-Object { $_ } | Select-Object -First 1))
    $detectedCores = ($instances | ForEach-Object DetectedCores | Where-Object { $null -ne $_ } | Select-Object -First 1)
    $machineExists = $null -ne $machine
    $machineBaseReady = $machineExists -and
        ([string](Get-ObjectValue -InputObject $machine -Paths @('properties.status', 'properties.connectionStatus')) -ieq 'Connected') -and
        ([string](Get-ObjectValue -InputObject $machine -Paths @('properties.agentConfiguration.mode')) -ieq 'Full') -and
        ([string](Get-ObjectValue -InputObject $machine -Paths @('properties.osName', 'properties.osType')) -match '(?i)Windows') -and
        -not [string]::IsNullOrWhiteSpace([string]$machine.location) -and
        ([string](Get-ObjectValue -InputObject $machine -Paths @('properties.detectedProperties.cloudProvider', 'properties.cloudMetadataProvider')) -ine 'Azure') -and
        ($regionSupported -eq $true) -and
        $hybridRegistered -and $arcDataRegistered
    $readyForInstall = $machineBaseReady -and -not $extension
    $enablementBlockers = @($blocking | Where-Object { $_ -notmatch '^Inventory timestamp|^Usage timestamp' })
    $readyForEnablement = $machineBaseReady -and $extensionSupported -and $sqlManagementEnabled -and ($licenseType -in @('Paid', 'PAYG')) -and ($eligibleInstances.Count -gt 0) -and ($enablementBlockers.Count -eq 0)

    return [pscustomobject][ordered]@{
        SubscriptionId = $Plan.SubscriptionId
        ResourceGroupName = $Plan.ResourceGroupName
        MachineName = $Plan.MachineName
        MachineResourceId = $machineId
        MachineExists = $machineExists
        ConnectionStatus = if ($machine) { [string](Get-ObjectValue -InputObject $machine -Paths @('properties.status', 'properties.connectionStatus')) } else { $null }
        AgentMode = if ($machine) { [string](Get-ObjectValue -InputObject $machine -Paths @('properties.agentConfiguration.mode')) } else { $null }
        OperatingSystem = if ($machine) { [string](Get-ObjectValue -InputObject $machine -Paths @('properties.osName', 'properties.osType')) } else { $null }
        Location = if ($machine) { [string]$machine.location } else { $null }
        HybridComputeRegistered = $hybridRegistered
        AzureArcDataRegistered = $arcDataRegistered
        RegionSupported = $regionSupported
        ExtensionState = $extensionState
        ExtensionVersion = $extensionVersion
        ExtensionSupported = $extensionSupported
        AutomaticUpgradeEnabled = $automaticUpgrade
        LicenseType = $licenseType
        SqlManagementEnabled = $sqlManagementEnabled
        ESUEnabled = $esuEnabled
        ESULastUpdatedTimestamp = $esuTimestamp
        EligibleInstances = $eligibleInstances
        IneligibleInstances = $ineligibleInstances
        MixedEligibleVersions = $mixedVersions
        HostType = $hostType
        DetectedCores = $detectedCores
        InventoryFreshness = $inventoryFreshness
        UsageFreshness = $usageFreshness
        BlockingIssues = @($blocking)
        Warnings = @($warnings)
        ExternalChecks = $external
        ReadyForExtensionInstall = $readyForInstall
        ReadyForESUEnablement = $readyForEnablement
    }
}

function Export-PrerequisiteResults {
    param(
        [Parameter(Mandatory = $true)][object[]]$Results,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $Results | ForEach-Object {
        $copy = $_ | Select-Object *
        $copy.EligibleInstances = (@($_.EligibleInstances | ForEach-Object { "$($_.Name)|$($_.Version)|$($_.Edition)|$($_.Eligibility)" }) -join '; ')
        $copy.IneligibleInstances = (@($_.IneligibleInstances | ForEach-Object { "$($_.Name)|$($_.Version)|$($_.Edition)|$($_.Eligibility)" }) -join '; ')
        $copy.BlockingIssues = @($_.BlockingIssues) -join '; '
        $copy.Warnings = @($_.Warnings) -join '; '
        $copy.ExternalChecks = @($_.ExternalChecks) -join '; '
        $copy
    } | Export-Csv -LiteralPath $Path -NoTypeInformation -ErrorAction Stop
}

$exitCode = 0
try {
    if ($PSCmdlet.ParameterSetName -eq 'Csv') {
        $rows = @(Import-Csv -LiteralPath $csvFilePath -ErrorAction Stop)
        $plans = @(ConvertTo-PrerequisitePlan -Rows $rows -DefaultSubscriptionId $subscriptionId)
    }
    else {
        $plans = @([pscustomobject]@{
            SubscriptionId = $subscriptionId
            ResourceGroupName = $serverResourceGroupName
            MachineName = $ARCServerName
        })
    }
}
catch {
    Write-Error "Input validation failed: $($_.Exception.Message)"
    exit 1
}

try {
    if ($userToken) { $token = ConvertTo-PlainTextToken -TokenObject $userToken }
    elseif ($tenantId -and $appID -and $clientSecret) {
        $token = Get-AzureADBearerToken -appID $appID -clientSecret $clientSecret -tenantId $tenantId
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Authentication failed.' }
    }
    else { throw 'Provide either userToken or tenantId, appID, and clientSecret.' }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

$headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
$results = @($plans | ForEach-Object { Get-PrerequisiteResult -Plan $_ -Headers $headers })
$results

if ($exportCsvPath) {
    try { Export-PrerequisiteResults -Results $results -Path $exportCsvPath }
    catch { Write-Error "Failed to export prerequisite results: $($_.Exception.Message)"; $exitCode = 1 }
}
if ($results | Where-Object { -not $_.MachineExists -or ($_.BlockingIssues | Where-Object { $_ -like 'Assessment failed:*' }) }) { $exitCode = 1 }
exit $exitCode