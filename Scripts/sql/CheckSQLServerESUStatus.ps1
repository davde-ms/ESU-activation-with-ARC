<#
.SYNOPSIS
Reports SQL Server Extended Security Update status for Azure Arc-enabled machines.

.DESCRIPTION
Performs read-only Azure Resource Manager requests for an Arc machine, its
WindowsAgent.SqlServer extension, provider registration, and correlated Azure Arc
SQL Server instances. Supports one machine or a CSV containing SubscriptionId,
ServerResourceGroupName, and ARCServerName. All input is validated before
authentication. This script never creates, updates, registers, or deletes a resource.

.EXAMPLE
$token = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
./Scripts/sql/CheckSQLServerESUStatus.ps1 -subscriptionId '00000000-0000-0000-0000-000000000001' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01' -userToken $token

.EXAMPLE
./Scripts/sql/CheckSQLServerESUStatus.ps1 -subscriptionId '00000000-0000-0000-0000-000000000001' -csvFilePath '.\machines.csv' -tenantId '00000000-0000-0000-0000-000000000002' -appID '00000000-0000-0000-0000-000000000003' -clientSecret 'fictitious-secret' -exportCsvPath '.\status.csv'
#>

[CmdletBinding(DefaultParameterSetName = 'SingleMachine')]
param(
    [Parameter(Mandatory, ParameterSetName = 'SingleMachine')]
    [Parameter(ParameterSetName = 'Csv')]
    [Alias('sub')]
    [string]$subscriptionId,

    [Parameter(Mandatory, ParameterSetName = 'SingleMachine')]
    [Alias('srg')]
    [string]$serverResourceGroupName,

    [Parameter(Mandatory, ParameterSetName = 'SingleMachine')]
    [Alias('server')]
    [string]$ARCServerName,

    [Parameter(Mandatory, ParameterSetName = 'Csv')]
    [Alias('csv')]
    [string]$csvFilePath,

    [string]$tenantId,

    [string]$appID,

    [Alias('s', 'secret', 'sec')]
    [string]$clientSecret,

    [Alias('token')]
    [object]$userToken,

    [Alias('export')]
    [string]$exportCsvPath
)

$script:Configuration = @{
    ArmEndpoint = 'https://management.azure.com'
    LoginEndpoint = 'https://login.microsoftonline.com'
    MachineApiVersion = '2026-07-15'
    ExtensionApiVersion = '2026-07-15'
    SqlInstanceApiVersion = '2026-01-01'
    ProviderApiVersion = '2021-04-01'
    ExtensionName = 'WindowsAgent.SqlServer'
    ExtensionPublisher = 'Microsoft.AzureData'
    SupportedExtensionVersions = @('1.1.3518.465')
    RequestAttempts = 4
    MaximumPageCount = 100
    MaximumRetryDelaySeconds = 8
}

function Test-SubscriptionId {
    param([AllowNull()][string]$Value)

    return -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

function Test-ResourceGroupName {
    param([AllowNull()][string]$Value)

    return -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value -match '^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$'
}

function Test-MachineName {
    param([AllowNull()][string]$Value)

    return -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value -match '^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,54}$'
}

function ConvertTo-StatusPlan {
    param(
        [Parameter(Mandatory)][string]$ParameterSetName,
        [AllowNull()][string]$DefaultSubscriptionId,
        [AllowNull()][string]$ResourceGroupName,
        [AllowNull()][string]$MachineName,
        [AllowNull()][string]$Path
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $items = [System.Collections.Generic.List[object]]::new()

    if ($ParameterSetName -eq 'SingleMachine') {
        $sourceRows = @([pscustomobject]@{
            SubscriptionId = $DefaultSubscriptionId
            ServerResourceGroupName = $ResourceGroupName
            ARCServerName = $MachineName
        })
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return [pscustomobject]@{ Items = @(); Errors = @("CSV file does not exist: '$Path'.") }
        }
        if ([System.IO.Path]::GetExtension($Path) -ine '.csv') {
            return [pscustomobject]@{ Items = @(); Errors = @("CSV file must have a .csv extension: '$Path'.") }
        }
        try {
            $sourceRows = @(Import-Csv -LiteralPath $Path -ErrorAction Stop)
        }
        catch {
            return [pscustomobject]@{ Items = @(); Errors = @("Unable to import CSV file: $($_.Exception.Message)") }
        }
        if ($sourceRows.Count -eq 0) {
            return [pscustomobject]@{ Items = @(); Errors = @('CSV file contains no data rows.') }
        }

        $requiredColumns = @('SubscriptionId', 'ServerResourceGroupName', 'ARCServerName')
        $actualColumns = @($sourceRows[0].PSObject.Properties.Name)
        $missingColumns = @($requiredColumns | Where-Object { $_ -notin $actualColumns })
        if ($missingColumns.Count -gt 0) {
            return [pscustomobject]@{ Items = @(); Errors = @("CSV is missing required columns: $($missingColumns -join ', ').") }
        }
        foreach ($column in @($actualColumns | Where-Object { $_ -notin $requiredColumns })) {
            Write-Warning "Ignoring unsupported CSV column '$column'."
        }
    }

    $seenResourceIds = @{}
    for ($index = 0; $index -lt $sourceRows.Count; $index++) {
        $row = $sourceRows[$index]
        $rowNumber = $index + 2
        $effectiveSubscriptionId = if ([string]::IsNullOrWhiteSpace([string]$row.SubscriptionId)) {
            ([string]$DefaultSubscriptionId).Trim()
        }
        else {
            ([string]$row.SubscriptionId).Trim()
        }
        $effectiveResourceGroup = ([string]$row.ServerResourceGroupName).Trim()
        $effectiveMachineName = ([string]$row.ARCServerName).Trim()
        $rowErrors = [System.Collections.Generic.List[string]]::new()

        if (-not (Test-SubscriptionId $effectiveSubscriptionId)) { $rowErrors.Add('SubscriptionId must be a valid GUID supplied by the row or command.') }
        if (-not (Test-ResourceGroupName $effectiveResourceGroup)) { $rowErrors.Add('ServerResourceGroupName is invalid.') }
        if (-not (Test-MachineName $effectiveMachineName)) { $rowErrors.Add('ARCServerName must be 1-54 supported characters.') }

        $resourceId = "/subscriptions/$effectiveSubscriptionId/resourceGroups/$effectiveResourceGroup/providers/Microsoft.HybridCompute/machines/$effectiveMachineName"
        $identityKey = $resourceId.ToLowerInvariant()
        if ($rowErrors.Count -eq 0) {
            if ($seenResourceIds.ContainsKey($identityKey)) {
                $rowErrors.Add("Duplicate machine target; first specified on row $($seenResourceIds[$identityKey]).")
            }
            else {
                $seenResourceIds[$identityKey] = $rowNumber
            }
        }

        if ($rowErrors.Count -gt 0) {
            $errors.Add("Row ${rowNumber}: $($rowErrors -join ' ')")
            continue
        }
        $items.Add([pscustomobject]@{
            SubscriptionId = $effectiveSubscriptionId
            ResourceGroupName = $effectiveResourceGroup
            MachineName = $effectiveMachineName
            MachineResourceId = $resourceId
        })
    }

    return [pscustomobject]@{ Items = $items.ToArray(); Errors = $errors.ToArray() }
}

function Get-BearerToken {
    param(
        [AllowNull()][object]$TokenObject,
        [AllowNull()][string]$Tenant,
        [AllowNull()][string]$ApplicationId,
        [AllowNull()][string]$Secret
    )

    if ($null -ne $TokenObject) {
        if ($Tenant -or $ApplicationId -or $Secret) { throw 'Provide either userToken or the complete service principal credentials, not both.' }
        if ($null -eq $TokenObject.PSObject.Properties['ExpiresOn'] -or $TokenObject.ExpiresOn -le (Get-Date)) {
            throw 'The provided user token is expired or has no valid expiration time.'
        }
        if ($null -eq $TokenObject.PSObject.Properties['Token'] -or $null -eq $TokenObject.Token) {
            throw 'The provided user token object has no Token value.'
        }
        if ($TokenObject.Token -is [securestring]) {
            return ConvertFrom-SecureString -SecureString $TokenObject.Token -AsPlainText
        }
        if ([string]::IsNullOrWhiteSpace([string]$TokenObject.Token)) { throw 'The provided user token is empty.' }
        return [string]$TokenObject.Token
    }

    if (-not (Test-SubscriptionId $Tenant) -or -not (Test-SubscriptionId $ApplicationId) -or [string]::IsNullOrWhiteSpace($Secret)) {
        throw 'Provide userToken or valid tenantId, appID, and clientSecret values.'
    }
    $authBody = @{
        grant_type = 'client_credentials'
        client_id = $ApplicationId
        client_secret = $Secret
        resource = "$($script:Configuration.ArmEndpoint)/"
    }
    $response = Invoke-WebRequest -Method Post -Uri "$($script:Configuration.LoginEndpoint)/$Tenant/oauth2/token" -ContentType 'application/x-www-form-urlencoded' -Body $authBody -ErrorAction Stop
    $authResponse = $response.Content | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$authResponse.access_token)) { throw 'Authentication response did not contain an access token.' }
    return [string]$authResponse.access_token
}

function Get-ObjectValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string[]]$Paths
    )

    foreach ($path in $Paths) {
        $value = $InputObject
        foreach ($segment in $path.Split('.')) {
            if ($null -eq $value -or $null -eq $value.PSObject.Properties[$segment]) {
                $value = $null
                break
            }
            $value = $value.$segment
        }
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { return $value }
    }
    return $null
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

function ConvertTo-NormalizedResourceId {
    param([AllowNull()][string]$ResourceId)

    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return '' }
    return $ResourceId.Trim().TrimEnd('/').ToLowerInvariant()
}

function Test-NotFoundError {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    if ($ErrorRecord.Exception.Response -and [int]$ErrorRecord.Exception.Response.StatusCode -eq 404) { return $true }
    return $ErrorRecord.Exception.Message -match '(^|\D)404(\D|$)|NotFound|not found'
}

function Get-HeaderValue {
    param(
        [AllowNull()][object]$Headers,
        [Parameter(Mandatory)][string[]]$Names
    )

    if ($null -eq $Headers) { return $null }
    foreach ($name in $Names) {
        if ($Headers -is [System.Collections.IDictionary]) {
            foreach ($key in $Headers.Keys) {
                if ([string]$key -ieq $name) { return [string]$Headers[$key] }
            }
        }
        elseif ($null -ne $Headers.PSObject.Properties[$name]) {
            return [string]$Headers.$name
        }
    }
    return $null
}

function Get-HttpStatusCode {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    if ($ErrorRecord.Exception.Response -and $null -ne $ErrorRecord.Exception.Response.StatusCode) {
        return [int]$ErrorRecord.Exception.Response.StatusCode
    }
    $statusMatch = [regex]::Match($ErrorRecord.Exception.Message, '(^|\D)(408|429|500|502|503|504|404)(\D|$)')
    if ($statusMatch.Success) { return [int]$statusMatch.Groups[2].Value }
    return 0
}

function Get-RetryDelaySeconds {
    param(
        [AllowNull()][object]$Headers,
        [Parameter(Mandatory)][int]$FallbackSeconds
    )

    $milliseconds = 0
    $retryAfterMilliseconds = Get-HeaderValue -Headers $Headers -Names @('x-ms-retry-after-ms')
    if ([int]::TryParse($retryAfterMilliseconds, [ref]$milliseconds) -and $milliseconds -ge 0) {
        return [math]::Min([int][math]::Ceiling($milliseconds / 1000), $script:Configuration.MaximumRetryDelaySeconds)
    }

    $seconds = 0
    $retryAfter = Get-HeaderValue -Headers $Headers -Names @('Retry-After')
    if ([int]::TryParse($retryAfter, [ref]$seconds) -and $seconds -ge 0) {
        return [math]::Min($seconds, $script:Configuration.MaximumRetryDelaySeconds)
    }
    $retryDate = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($retryAfter, [ref]$retryDate)) {
        $dateDelay = [int][math]::Ceiling(($retryDate - [datetimeoffset]::UtcNow).TotalSeconds)
        return [math]::Min([math]::Max($dateDelay, 0), $script:Configuration.MaximumRetryDelaySeconds)
    }
    return [math]::Min($FallbackSeconds, $script:Configuration.MaximumRetryDelaySeconds)
}

function Invoke-ArmGet {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $transientStatusCodes = @(408, 429, 500, 502, 503, 504)
    for ($attempt = 1; $attempt -le $script:Configuration.RequestAttempts; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Uri -Method GET -Headers $Headers -ErrorAction Stop
        }
        catch {
            $statusCode = Get-HttpStatusCode -ErrorRecord $_
            if ($statusCode -notin $transientStatusCodes -or $attempt -eq $script:Configuration.RequestAttempts) {
                $statusText = if ($statusCode -gt 0) { "HTTP $statusCode" } else { 'HTTP status unavailable' }
                throw "ARM GET failed after $attempt attempt(s) ($statusText)."
            }
            $responseHeaders = if ($_.Exception.Response) { $_.Exception.Response.Headers } else { $null }
            $fallbackSeconds = [int][math]::Pow(2, $attempt - 1)
            Start-Sleep -Seconds (Get-RetryDelaySeconds -Headers $responseHeaders -FallbackSeconds $fallbackSeconds)
        }
    }
}

function Assert-TrustedArmNextLink {
    param([Parameter(Mandatory)][string]$NextLink)

    $parsedUri = $null
    if (-not [uri]::TryCreate($NextLink, [UriKind]::Absolute, [ref]$parsedUri) -or
        $parsedUri.Scheme -ine 'https' -or
        $parsedUri.Host -ine 'management.azure.com' -or
        -not $parsedUri.IsDefaultPort -or
        -not [string]::IsNullOrWhiteSpace($parsedUri.UserInfo)) {
        throw 'ARM pagination nextLink must use HTTPS and the management.azure.com host on its default port.'
    }
}

function Get-AllSqlServerInstances {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $instances = [System.Collections.Generic.List[object]]::new()
    $nextLink = "$($script:Configuration.ArmEndpoint)/subscriptions/$SubscriptionId/providers/Microsoft.AzureArcData/sqlServerInstances?api-version=$($script:Configuration.SqlInstanceApiVersion)"
    $visitedLinks = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pageCount = 0
    while (-not [string]::IsNullOrWhiteSpace($nextLink)) {
        Assert-TrustedArmNextLink -NextLink $nextLink
        if (-not $visitedLinks.Add(([uri]$nextLink).AbsoluteUri)) { throw 'ARM pagination returned a previously visited nextLink.' }
        $pageCount++
        if ($pageCount -gt $script:Configuration.MaximumPageCount) { throw "ARM pagination exceeded the $($script:Configuration.MaximumPageCount)-page limit." }
        $page = Invoke-ArmGet -Uri $nextLink -Headers $Headers
        foreach ($instance in @($page.value)) { $instances.Add($instance) }
        $nextLink = [string]$page.nextLink
    }
    return $instances.ToArray()
}

function Get-TimestampFreshness {
    param(
        [AllowNull()][object]$Value,
        [datetime]$Now = [datetime]::UtcNow
    )

    $timestamp = [datetime]::MinValue
    if ($null -eq $Value -or -not [datetime]::TryParse([string]$Value, [ref]$timestamp)) { return 'Unknown' }
    if ($timestamp.ToUniversalTime() -lt $Now.ToUniversalTime().AddHours(-24)) { return 'Stale' }
    return 'Fresh'
}

function Get-SqlInstanceStatus {
    param([Parameter(Mandatory)][object]$Instance)

    $version = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.version', 'properties.currentVersion', 'properties.productVersion'))
    $edition = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.edition', 'properties.currentEdition'))
    $eligibleVersion = if ($version -match '(?i)SQL\s*Server\s*2014|^12(\.|$)') {
        'SQL Server 2014'
    }
    elseif ($version -match '(?i)SQL\s*Server\s*2016|^13(\.|$)') {
        'SQL Server 2016'
    }
    else {
        $null
    }
    $baseEligibility = if (-not $eligibleVersion) {
        'UnsupportedVersion'
    }
    elseif ($edition -match '(?i)\bDeveloper\b') {
        'DeveloperNonProductionUncertain'
    }
    elseif ($edition -match '(?i)\b(Standard|Enterprise)\b') {
        'SupportedEligible'
    }
    else {
        'IneligibleEdition'
    }

    $inventoryTimestamp = Get-ObjectValue -InputObject $Instance -Paths @('properties.lastInventoryUploadTime')
    $usageTimestamp = Get-ObjectValue -InputObject $Instance -Paths @('properties.lastUsageUploadTime')
    $inventoryFreshness = Get-TimestampFreshness -Value $inventoryTimestamp
    $usageFreshness = Get-TimestampFreshness -Value $usageTimestamp
    $eligibility = if ($baseEligibility -eq 'SupportedEligible' -and
        ($inventoryFreshness -ne 'Fresh' -or $usageFreshness -ne 'Fresh')) {
        'InventoryOrUsageUncertain'
    }
    else {
        $baseEligibility
    }
    $environment = Get-ObjectValue -InputObject $Instance -Paths @(
        'properties.environment',
        'properties.usageEnvironment',
        'properties.licenseDetails.environment'
    )
    $passiveState = Get-ObjectValue -InputObject $Instance -Paths @(
        'properties.isPassive',
        'properties.isDisasterRecovery',
        'properties.licenseDetails.isPassive',
        'properties.licenseDetails.isDisasterRecovery',
        'properties.failoverCluster.isPassive'
    )
    return [pscustomobject][ordered]@{
        Name = [string]$Instance.name
        ResourceId = [string]$Instance.id
        Version = $version
        EligibleVersion = $eligibleVersion
        Edition = $edition
        Eligibility = $eligibility
        BaseEligibility = $baseEligibility
        Environment = $environment
        ServiceType = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.serviceType'))
        Status = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.status'))
        HostType = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.hostType', 'properties.hostingType'))
        DetectedCores = Get-ObjectValue -InputObject $Instance -Paths @('properties.vCore', 'properties.vCores', 'properties.coreCount', 'properties.cores', 'properties.hostResources.logicalCores')
        InventoryTimestamp = $inventoryTimestamp
        UsageTimestamp = $usageTimestamp
        InventoryFreshness = $inventoryFreshness
        UsageFreshness = $usageFreshness
        PatchLevel = Get-ObjectValue -InputObject $Instance -Paths @('properties.patchLevel', 'properties.currentVersion')
        PassiveDRState = $passiveState
    }
}

function Get-Freshness {
    param(
        [Parameter(Mandatory)][object[]]$Instances,
        [Parameter(Mandatory)][ValidateSet('InventoryTimestamp', 'UsageTimestamp')][string]$PropertyName,
        [datetime]$Now = [datetime]::UtcNow
    )

    if ($Instances.Count -eq 0) { return 'Unknown' }
    foreach ($instance in $Instances) {
        $freshness = Get-TimestampFreshness -Value $instance.$PropertyName -Now $Now
        if ($freshness -eq 'Unknown') { return 'Unknown' }
        if ($freshness -eq 'Stale') { return 'Stale' }
    }
    return 'Fresh'
}

function Get-ProviderRegistration {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ProviderNamespace,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $uri = "$($script:Configuration.ArmEndpoint)/subscriptions/$SubscriptionId/providers/$ProviderNamespace`?api-version=$($script:Configuration.ProviderApiVersion)"
    return Invoke-ArmGet -Uri $uri -Headers $Headers
}

function Get-ErrorStatusResult {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$Reason
    )

    return [pscustomobject][ordered]@{
        SubscriptionId = $Plan.SubscriptionId; ResourceGroupName = $Plan.ResourceGroupName; MachineName = $Plan.MachineName
        MachineResourceId = $Plan.MachineResourceId; Evaluated = $false; MachineExists = $null; ConnectionStatus = $null
        AgentMode = $null; OperatingSystem = $null; NativeAzureExcluded = $null; Location = $null
        HybridComputeRegistered = $null; AzureArcDataRegistered = $null; ExtensionInstalled = $null
        ExtensionPublisher = $null; ExtensionType = $null; ExtensionProvisioningState = $null; ExtensionVersion = $null
        ExtensionVersionSupport = 'Unknown'; AutomaticUpgradeEnabled = $null; LicenseType = $null
        SqlManagementEnabled = $null; ESUEnabled = $null; ESURawValue = $null; ESULastUpdatedTimestamp = $null
        Instances = @(); EligibleInstances = @(); IneligibleInstances = @(); UncertainInstances = @()
        EligibleVersions = @(); Editions = @(); Environments = @(); MixedEligibleVersions = $false
        HostType = $null; HostTypes = @(); HostTypeEvidenceStatus = 'Unknown'; DetectedCores = $null
        DetectedCoreValues = @(); DetectedCoresEvidenceStatus = 'Unknown'; MeteringEvidenceStatus = 'Uncertain'
        InventoryFreshness = 'Unknown'; UsageFreshness = 'Unknown'
        AutomaticPatchStatus = $null; PassiveDRState = @(); Classification = 'Error'; Reasons = @($Reason); Warnings = @()
    }
}

function Get-SqlServerEsuStatus {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$ProviderCache,
        [Parameter(Mandatory)][hashtable]$InstanceCache
    )

    try {
        if (-not $ProviderCache.ContainsKey($Plan.SubscriptionId)) {
            $ProviderCache[$Plan.SubscriptionId] = [pscustomobject]@{
                HybridCompute = Get-ProviderRegistration -SubscriptionId $Plan.SubscriptionId -ProviderNamespace 'Microsoft.HybridCompute' -Headers $Headers
                AzureArcData = Get-ProviderRegistration -SubscriptionId $Plan.SubscriptionId -ProviderNamespace 'Microsoft.AzureArcData' -Headers $Headers
            }
        }
        if (-not $InstanceCache.ContainsKey($Plan.SubscriptionId)) {
            $InstanceCache[$Plan.SubscriptionId] = @(Get-AllSqlServerInstances -SubscriptionId $Plan.SubscriptionId -Headers $Headers)
        }

        $hybridRegistered = [string]$ProviderCache[$Plan.SubscriptionId].HybridCompute.registrationState -ieq 'Registered'
        $arcDataRegistered = [string]$ProviderCache[$Plan.SubscriptionId].AzureArcData.registrationState -ieq 'Registered'
        $machineUri = "$($script:Configuration.ArmEndpoint)$($Plan.MachineResourceId)?api-version=$($script:Configuration.MachineApiVersion)"
        try {
            $machine = Invoke-ArmGet -Uri $machineUri -Headers $Headers
        }
        catch {
            if (Test-NotFoundError -ErrorRecord $_) { return Get-ErrorStatusResult -Plan $Plan -Reason 'Arc machine was not found.' }
            throw
        }

        $extension = $null
        $extensionUri = "$($script:Configuration.ArmEndpoint)$($Plan.MachineResourceId)/extensions/$($script:Configuration.ExtensionName)?api-version=$($script:Configuration.ExtensionApiVersion)"
        try {
            $extension = Invoke-ArmGet -Uri $extensionUri -Headers $Headers
        }
        catch {
            if (-not (Test-NotFoundError -ErrorRecord $_)) { throw }
        }

        $instances = @($InstanceCache[$Plan.SubscriptionId] | Where-Object {
            (ConvertTo-NormalizedResourceId (Get-ObjectValue -InputObject $_ -Paths @('properties.containerResourceId'))) -eq
                (ConvertTo-NormalizedResourceId $Plan.MachineResourceId)
        } | ForEach-Object { Get-SqlInstanceStatus -Instance $_ })

        $reasons = [System.Collections.Generic.List[string]]::new()
        $warnings = [System.Collections.Generic.List[string]]::new()
        $connectionStatus = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.status', 'properties.connectionStatus'))
        $agentMode = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.agentConfiguration.mode'))
        $operatingSystem = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.osName', 'properties.osType'))
        $cloudProvider = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.detectedProperties.cloudProvider', 'properties.cloudMetadataProvider'))
        $nativeAzureExcluded = $cloudProvider -ieq 'Azure'
        $extensionInstalled = $null -ne $extension
        $extensionPublisher = if ($extension) { [string](Get-ObjectValue -InputObject $extension -Paths @('properties.publisher')) } else { $null }
        $extensionType = if ($extension) { [string](Get-ObjectValue -InputObject $extension -Paths @('properties.type')) } else { $null }
        $extensionState = if ($extension) { [string](Get-ObjectValue -InputObject $extension -Paths @('properties.provisioningState')) } else { 'NotInstalled' }
        $extensionVersion = if ($extension) { [string](Get-ObjectValue -InputObject $extension -Paths @('properties.typeHandlerVersion')) } else { $null }
        $extensionVersionSupport = if (-not $extension) {
            'NotInstalled'
        }
        elseif ([string]::IsNullOrWhiteSpace($extensionVersion)) {
            'Unknown'
        }
        elseif ($extensionVersion -in $script:Configuration.SupportedExtensionVersions) {
            'SupportedBaseline'
        }
        else {
            'Unknown'
        }
        $settings = if ($extension) { Get-ObjectValue -InputObject $extension -Paths @('properties.settings') } else { $null }
        $esuRaw = Get-ObjectValue -InputObject $settings -Paths @('enableExtendedSecurityUpdates')
        $esuEnabled = ConvertTo-BooleanValue $esuRaw
        $automaticUpgrade = ConvertTo-BooleanValue (Get-ObjectValue -InputObject $extension -Paths @('properties.enableAutomaticUpgrade', 'properties.autoUpgradeMinorVersion'))
        $sqlManagement = ConvertTo-BooleanValue (Get-ObjectValue -InputObject $settings -Paths @('SqlManagement.IsEnabled'))
        $licenseType = [string](Get-ObjectValue -InputObject $settings -Paths @('LicenseType'))
        $automaticPatchStatus = Get-ObjectValue -InputObject $settings -Paths @(
            'AutomaticPatching.IsEnabled',
            'AutoPatchingSettings.IsEnabled',
            'PatchSettings.IsEnabled',
            'SqlManagement.AutomaticUpdatesEnabled'
        )
        $eligibleInstances = @($instances | Where-Object BaseEligibility -eq 'SupportedEligible')
        $ineligibleInstances = @($instances | Where-Object BaseEligibility -in @('UnsupportedVersion', 'IneligibleEdition'))
        $uncertainInstances = @($instances | Where-Object Eligibility -in @('DeveloperNonProductionUncertain', 'InventoryOrUsageUncertain'))
        $eligibleVersions = @($eligibleInstances | ForEach-Object EligibleVersion | Select-Object -Unique)
        $editions = @($instances | ForEach-Object Edition | Where-Object { $_ } | Select-Object -Unique)
        $environments = @($instances | ForEach-Object Environment | Where-Object { $null -ne $_ } | Select-Object -Unique)
        $mixedVersions = $eligibleVersions.Count -gt 1
        $inventoryFreshness = Get-Freshness -Instances $instances -PropertyName InventoryTimestamp
        $usageFreshness = Get-Freshness -Instances $instances -PropertyName UsageTimestamp
        $passiveState = @($instances | ForEach-Object PassiveDRState | Where-Object { $null -ne $_ })
        $hostTypes = @($instances | ForEach-Object HostType | Where-Object { $_ } | Select-Object -Unique)
        $detectedCoreValues = @($instances | ForEach-Object DetectedCores | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
        $hostTypeEvidenceStatus = if ($hostTypes.Count -eq 0) { 'Missing' } elseif ($hostTypes.Count -eq 1) { 'Consistent' } else { 'Conflict' }
        $detectedCoresEvidenceStatus = if ($detectedCoreValues.Count -eq 0) { 'Missing' } elseif ($detectedCoreValues.Count -eq 1) { 'Consistent' } else { 'Conflict' }
        $meteringEvidenceStatus = if ($hostTypeEvidenceStatus -eq 'Consistent' -and $detectedCoresEvidenceStatus -eq 'Consistent') { 'Certain' } elseif ('Conflict' -in @($hostTypeEvidenceStatus, $detectedCoresEvidenceStatus)) { 'UncertainConflict' } else { 'UncertainMissing' }
        $hostType = if ($hostTypeEvidenceStatus -eq 'Consistent') { $hostTypes[0] } else { $null }
        $detectedCores = if ($detectedCoresEvidenceStatus -eq 'Consistent') { $detectedCoreValues[0] } else { $null }

        if (-not $hybridRegistered) { $warnings.Add('Microsoft.HybridCompute is not registered.') }
        if (-not $arcDataRegistered) { $warnings.Add('Microsoft.AzureArcData is not registered.') }
        if ($connectionStatus -ine 'Connected') { $warnings.Add("Arc machine connection status is '$connectionStatus'.") }
        if ($agentMode -ine 'Full') { $warnings.Add("Arc agent mode is '$agentMode', not 'Full'.") }
        if ($operatingSystem -notmatch '(?i)Windows') { $reasons.Add("Operating system '$operatingSystem' is outside this Windows-only workflow.") }
        if ($nativeAzureExcluded) { $reasons.Add('Native Azure virtual machines must use the SQL IaaS Agent extension, not this Arc workflow.') }
        if ($extension -and ($extensionPublisher -ine $script:Configuration.ExtensionPublisher -or $extensionType -ine $script:Configuration.ExtensionName)) {
            $reasons.Add('The extension has an unexpected publisher or type.')
        }
        if ($extension -and $extensionState -ine 'Succeeded') { $reasons.Add("SQL extension provisioning state is '$extensionState'.") }
        if ($extension -and $extensionVersionSupport -eq 'Unknown') {
            $warnings.Add("Extension version '$extensionVersion' is not established by the current explicit supported baseline; support is Unknown and should be checked against current release dates.")
        }
        if ($extension -and $automaticUpgrade -ne $true) { $warnings.Add('Automatic extension upgrade is not enabled or could not be determined.') }
        if ($extension -and $sqlManagement -ne $true) { $warnings.Add('SqlManagement.IsEnabled is not true or could not be determined.') }
        if ($extension -and $licenseType -notin @('Paid', 'PAYG')) { $warnings.Add("LicenseType '$licenseType' does not establish Arc-enabled SQL Server ESU eligibility.") }
        if ($mixedVersions) { $warnings.Add('Both SQL Server 2014 and SQL Server 2016 are eligible; each version can produce a separate ESU meter.') }
        if ($inventoryFreshness -ne 'Fresh') { $warnings.Add("Inventory freshness is $inventoryFreshness; data older than 24 hours or missing is warning-only.") }
        if ($usageFreshness -ne 'Fresh') { $warnings.Add("Usage freshness is $usageFreshness; data older than 24 hours or missing is warning-only.") }
        if ($hostTypeEvidenceStatus -eq 'Missing') { $warnings.Add('Host type evidence is missing; metering basis is uncertain.') }
        elseif ($hostTypeEvidenceStatus -eq 'Conflict') { $warnings.Add("Conflicting host type evidence was reported: $($hostTypes -join ', ').") }
        if ($detectedCoresEvidenceStatus -eq 'Missing') { $warnings.Add('Detected core evidence is missing; metering basis is uncertain.') }
        elseif ($detectedCoresEvidenceStatus -eq 'Conflict') { $warnings.Add("Conflicting detected core evidence was reported: $($detectedCoreValues -join ', ').") }
        if ($null -eq $automaticPatchStatus) { $warnings.Add('Automatic patch status is not exposed by the service response; ESU entitlement does not guarantee patch installation.') }

        $classification = if ($reasons.Count -gt 0) {
            'Error'
        }
        elseif (-not $extensionInstalled -or $esuEnabled -eq $false) {
            if (-not $extensionInstalled) { $reasons.Add('WindowsAgent.SqlServer is not installed.') }
            else { $reasons.Add('Extended Security Updates are not enabled in extension settings.') }
            'NotEnabled'
        }
        elseif ($null -eq $esuEnabled) {
            $reasons.Add('The ESU setting is missing or is not a recognized Boolean/string representation.')
            'Unknown'
        }
        elseif ($eligibleInstances.Count -eq 0) {
            $reasons.Add('No eligible SQL Server 2014 or SQL Server 2016 Standard/Enterprise instance was discovered.')
            'Unknown'
        }
        elseif ($warnings.Count -gt 0) {
            $reasons.Add('ESU is configured, but one or more health, support, eligibility, or freshness warnings require review.')
            'Warning'
        }
        else {
            $reasons.Add('ESU is enabled with a healthy extension, connected full-mode machine, and fresh eligible SQL inventory.')
            'Healthy'
        }

        return [pscustomobject][ordered]@{
            SubscriptionId = $Plan.SubscriptionId; ResourceGroupName = $Plan.ResourceGroupName; MachineName = $Plan.MachineName
            MachineResourceId = $Plan.MachineResourceId; Evaluated = $true; MachineExists = $true; ConnectionStatus = $connectionStatus
            AgentMode = $agentMode; OperatingSystem = $operatingSystem; NativeAzureExcluded = $nativeAzureExcluded; Location = [string]$machine.location
            HybridComputeRegistered = $hybridRegistered; AzureArcDataRegistered = $arcDataRegistered; ExtensionInstalled = $extensionInstalled
            ExtensionPublisher = $extensionPublisher; ExtensionType = $extensionType; ExtensionProvisioningState = $extensionState; ExtensionVersion = $extensionVersion
            ExtensionVersionSupport = $extensionVersionSupport; AutomaticUpgradeEnabled = $automaticUpgrade; LicenseType = $licenseType
            SqlManagementEnabled = $sqlManagement; ESUEnabled = $esuEnabled; ESURawValue = $esuRaw
            ESULastUpdatedTimestamp = Get-ObjectValue -InputObject $settings -Paths @('esuLastUpdatedTimestamp')
            Instances = $instances; EligibleInstances = $eligibleInstances; IneligibleInstances = $ineligibleInstances; UncertainInstances = $uncertainInstances
            EligibleVersions = $eligibleVersions; Editions = $editions; Environments = $environments; MixedEligibleVersions = $mixedVersions
            HostType = $hostType; HostTypes = $hostTypes; HostTypeEvidenceStatus = $hostTypeEvidenceStatus
            DetectedCores = $detectedCores; DetectedCoreValues = $detectedCoreValues; DetectedCoresEvidenceStatus = $detectedCoresEvidenceStatus
            MeteringEvidenceStatus = $meteringEvidenceStatus; InventoryFreshness = $inventoryFreshness; UsageFreshness = $usageFreshness
            AutomaticPatchStatus = $automaticPatchStatus; PassiveDRState = $passiveState; Classification = $classification
            Reasons = $reasons.ToArray(); Warnings = $warnings.ToArray()
        }
    }
    catch {
        return Get-ErrorStatusResult -Plan $Plan -Reason "Status evaluation failed: $($_.Exception.Message)"
    }
}

function Export-StatusResults {
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$Path
    )

    $Results | ForEach-Object {
        [pscustomobject][ordered]@{
            SubscriptionId = $_.SubscriptionId; ResourceGroupName = $_.ResourceGroupName; MachineName = $_.MachineName
            MachineResourceId = $_.MachineResourceId; Evaluated = $_.Evaluated; MachineExists = $_.MachineExists
            ConnectionStatus = $_.ConnectionStatus; AgentMode = $_.AgentMode; OperatingSystem = $_.OperatingSystem
            NativeAzureExcluded = $_.NativeAzureExcluded; Location = $_.Location; HybridComputeRegistered = $_.HybridComputeRegistered
            AzureArcDataRegistered = $_.AzureArcDataRegistered; ExtensionInstalled = $_.ExtensionInstalled
            ExtensionPublisher = $_.ExtensionPublisher; ExtensionType = $_.ExtensionType
            ExtensionProvisioningState = $_.ExtensionProvisioningState; ExtensionVersion = $_.ExtensionVersion
            ExtensionVersionSupport = $_.ExtensionVersionSupport; AutomaticUpgradeEnabled = $_.AutomaticUpgradeEnabled
            LicenseType = $_.LicenseType; SqlManagementEnabled = $_.SqlManagementEnabled; ESUEnabled = $_.ESUEnabled
            ESURawValue = [string]$_.ESURawValue; ESULastUpdatedTimestamp = $_.ESULastUpdatedTimestamp
            Instances = @($_.Instances | ForEach-Object { "$($_.Name)|$($_.Version)|$($_.Edition)|$($_.Eligibility)|$($_.Environment)|$($_.InventoryFreshness)|$($_.UsageFreshness)" }) -join '; '
            EligibleInstances = @($_.EligibleInstances | ForEach-Object { "$($_.Name)|$($_.Version)|$($_.Edition)|$($_.Eligibility)" }) -join '; '
            IneligibleInstances = @($_.IneligibleInstances | ForEach-Object { "$($_.Name)|$($_.Version)|$($_.Edition)|$($_.Eligibility)" }) -join '; '
            UncertainInstances = @($_.UncertainInstances | ForEach-Object { "$($_.Name)|$($_.Version)|$($_.Edition)|$($_.Eligibility)" }) -join '; '
            EligibleVersions = @($_.EligibleVersions) -join '; '; Editions = @($_.Editions) -join '; '
            Environments = @($_.Environments) -join '; '; MixedEligibleVersions = $_.MixedEligibleVersions
            HostType = $_.HostType; HostTypes = @($_.HostTypes) -join '; '; HostTypeEvidenceStatus = $_.HostTypeEvidenceStatus
            DetectedCores = $_.DetectedCores; DetectedCoreValues = @($_.DetectedCoreValues) -join '; '
            DetectedCoresEvidenceStatus = $_.DetectedCoresEvidenceStatus; MeteringEvidenceStatus = $_.MeteringEvidenceStatus
            InventoryFreshness = $_.InventoryFreshness; UsageFreshness = $_.UsageFreshness
            AutomaticPatchStatus = [string]$_.AutomaticPatchStatus; PassiveDRState = @($_.PassiveDRState) -join '; '
            Classification = $_.Classification; Reasons = @($_.Reasons) -join '; '; Warnings = @($_.Warnings) -join '; '
        }
    } | Export-Csv -LiteralPath $Path -NoTypeInformation -ErrorAction Stop
}

$planResult = ConvertTo-StatusPlan -ParameterSetName $PSCmdlet.ParameterSetName -DefaultSubscriptionId $subscriptionId -ResourceGroupName $serverResourceGroupName -MachineName $ARCServerName -Path $csvFilePath
if ($planResult.Errors.Count -gt 0) {
    Write-Error "Input validation failed:$([Environment]::NewLine)$($planResult.Errors -join [Environment]::NewLine)"
    exit 1
}

try {
    $bearerToken = Get-BearerToken -TokenObject $userToken -Tenant $tenantId -ApplicationId $appID -Secret $clientSecret
}
catch {
    Write-Error "Authentication failed: $($_.Exception.Message)"
    exit 1
}

$headers = @{ Authorization = "Bearer $bearerToken"; Accept = 'application/json' }
$providerCache = @{}
$instanceCache = @{}
$results = @($planResult.Items | ForEach-Object {
    Get-SqlServerEsuStatus -Plan $_ -Headers $headers -ProviderCache $providerCache -InstanceCache $instanceCache
})
$results

$exitCode = 0
if ($exportCsvPath) {
    try { Export-StatusResults -Results $results -Path $exportCsvPath }
    catch { Write-Error "Failed to export status results: $($_.Exception.Message)"; $exitCode = 1 }
}
if ($results | Where-Object { -not $_.Evaluated }) { $exitCode = 1 }
exit $exitCode