<#
.SYNOPSIS
Enables or disables a SQL Server ESU subscription on an existing Arc-enabled Windows machine.

.DESCRIPTION
Updates the host-level WindowsAgent.SqlServer extension by using direct Azure Resource
Manager REST calls. The script validates all local input before authentication and completes
read-only Azure preflight for every target before any mutation. It preserves all existing
public extension settings and changes only the ESU Boolean, its UTC timestamp, and an
explicitly approved enable-time LicenseType change.

The target must already be connected to commercial Azure Arc in full mode and have a
healthy, supported Azure Extension for SQL Server. The script does not install or repair
agents, accept core counts, manage physical-core pools, or configure patching.

.EXAMPLE
$token = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
./Scripts/sql/SetSQLServerESUSubscription.ps1 -subscriptionId '00000000-0000-0000-0000-000000000001' `
    -serverResourceGroupName 'rg-arc-servers' -ARCServerName 'sql-host-01' -Action Enable `
    -Environment Production -AcceptBackBilling -ConfirmExternalPrerequisites -userToken $token -DryRun

.EXAMPLE
./Scripts/sql/SetSQLServerESUSubscription.ps1 -subscriptionId '00000000-0000-0000-0000-000000000001' `
    -csvFilePath 'C:\Temp\SetSQLServerESUSubscription.csv' -userToken $token -WhatIf
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Single', ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [Parameter(ParameterSetName = 'Csv')]
    [Alias('sub')]
    [string]$subscriptionId,

    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [Alias('srg')]
    [string]$serverResourceGroupName,

    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [Alias('server')]
    [string]$ARCServerName,

    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [ValidateSet('Enable', 'Disable')]
    [string]$Action,

    [Parameter(ParameterSetName = 'Single')]
    [ValidateSet('Paid', 'PAYG')]
    [string]$LicenseType,

    [Parameter(ParameterSetName = 'Single')]
    [ValidateSet('Production', 'NonProduction')]
    [string]$Environment,

    [Parameter(ParameterSetName = 'Single')]
    [switch]$AcceptBackBilling,

    [Parameter(ParameterSetName = 'Single')]
    [switch]$AcceptLicenseTypeChange,

    [Parameter(ParameterSetName = 'Single')]
    [switch]$ConfirmNonProductionCoverage,

    [Parameter(ParameterSetName = 'Single')]
    [switch]$ConfirmExternalPrerequisites,

    [Parameter(Mandatory, ParameterSetName = 'Csv')]
    [Alias('csv')]
    [string]$csvFilePath,

    [string]$tenantId,

    [string]$appID,

    [Alias('s', 'secret', 'sec')]
    [string]$clientSecret,

    [Alias('token')]
    [object]$userToken,

    [Alias('Preview')]
    [switch]$DryRun
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
    PollAttempts = 12
    PollIntervalSeconds = 5
    RequestAttempts = 4
    RequestRetryIntervalSeconds = 2
}

function Test-SubscriptionId {
    param([string]$Value)

    return -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

function Test-ResourceGroupName {
    param([string]$Value)

    return -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value -match '^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$'
}

function Test-MachineName {
    param([string]$Value)

    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[a-zA-Z0-9_\-.]{1,54}$'
}

function ConvertTo-StrictBoolean {
    param(
        [AllowNull()][object]$Value,
        [switch]$AllowEmpty
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        if ($AllowEmpty) { return $null }
        throw 'A TRUE or FALSE value is required.'
    }
    if ($Value -is [bool]) { return $Value }
    if ([string]$Value -ieq 'TRUE') { return $true }
    if ([string]$Value -ieq 'FALSE') { return $false }
    throw "Value '$Value' must be TRUE or FALSE."
}

function ConvertTo-CanonicalLicenseType {
    param([AllowNull()][object]$Value)

    $text = [string]$Value
    if ($text -ieq 'Paid') { return 'Paid' }
    if ($text -ieq 'PAYG') { return 'PAYG' }
    return $text
}

function Get-StringDistance {
    param([string]$Left, [string]$Right)

    $previous = [int[]](0..$Right.Length)
    for ($leftIndex = 1; $leftIndex -le $Left.Length; $leftIndex++) {
        $current = [int[]]::new($Right.Length + 1)
        $current[0] = $leftIndex
        for ($rightIndex = 1; $rightIndex -le $Right.Length; $rightIndex++) {
            $cost = if ($Left[$leftIndex - 1] -ceq $Right[$rightIndex - 1]) { 0 } else { 1 }
            $current[$rightIndex] = [math]::Min(
                [math]::Min($current[$rightIndex - 1] + 1, $previous[$rightIndex] + 1),
                $previous[$rightIndex - 1] + $cost
            )
        }
        $previous = $current
    }
    return $previous[$Right.Length]
}

function Test-BillingControlLikeColumn {
    param([string]$Column, [string[]]$KnownColumns)

    $normalized = ($Column -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    foreach ($knownColumn in $KnownColumns) {
        $known = ($knownColumn -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
        if ((Get-StringDistance -Left $normalized -Right $known) -le 2) { return $true }
    }
    return $normalized -match '^(accept|confirm).*(bill|licen|cover|prereq|prerequis)'
}

function ConvertTo-PlanItems {
    param(
        [string]$ParameterSetName,
        [string]$DefaultSubscriptionId,
        [string]$ResourceGroupName,
        [string]$MachineName,
        [string]$RequestedAction,
        [string]$RequestedLicenseType,
        [string]$RequestedEnvironment,
        [bool]$BackBillingAccepted,
        [bool]$LicenseTypeChangeAccepted,
        [bool]$NonProductionCoverageConfirmed,
        [bool]$ExternalPrerequisitesConfirmed,
        [string]$Path
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $items = [System.Collections.Generic.List[object]]::new()

    if ($ParameterSetName -eq 'Single') {
        $sourceRows = @([pscustomobject]@{
            SubscriptionId = $DefaultSubscriptionId
            ServerResourceGroupName = $ResourceGroupName
            ARCServerName = $MachineName
            Action = $RequestedAction
            LicenseType = $RequestedLicenseType
            Environment = $RequestedEnvironment
            AcceptBackBilling = if ($BackBillingAccepted) { 'TRUE' } else { '' }
            AcceptLicenseTypeChange = if ($LicenseTypeChangeAccepted) { 'TRUE' } else { '' }
            ConfirmNonProductionCoverage = if ($NonProductionCoverageConfirmed) { 'TRUE' } else { '' }
            ConfirmExternalPrerequisites = if ($ExternalPrerequisitesConfirmed) { 'TRUE' } else { '' }
        })
    } else {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $errors.Add("CSV file does not exist: '$Path'.")
            return [pscustomobject]@{ Items = @(); Errors = $errors.ToArray() }
        }
        if ([System.IO.Path]::GetExtension($Path) -ine '.csv') {
            $errors.Add("CSV file must have a .csv extension: '$Path'.")
            return [pscustomobject]@{ Items = @(); Errors = $errors.ToArray() }
        }
        try {
            $sourceRows = @(Import-Csv -LiteralPath $Path -ErrorAction Stop)
        } catch {
            $errors.Add("Unable to import CSV file: $($_.Exception.Message)")
            return [pscustomobject]@{ Items = @(); Errors = $errors.ToArray() }
        }
        if ($sourceRows.Count -eq 0) {
            $errors.Add('CSV file contains no data rows.')
            return [pscustomobject]@{ Items = @(); Errors = $errors.ToArray() }
        }

        $requiredColumns = @(
            'SubscriptionId', 'ServerResourceGroupName', 'ARCServerName', 'Action', 'LicenseType',
            'Environment', 'AcceptBackBilling', 'AcceptLicenseTypeChange',
            'ConfirmNonProductionCoverage', 'ConfirmExternalPrerequisites'
        )
        $actualColumns = @($sourceRows[0].PSObject.Properties.Name)
        $missingColumns = @($requiredColumns | Where-Object { $_ -notin $actualColumns })
        if ($missingColumns.Count -gt 0) {
            $errors.Add("CSV is missing required columns: $($missingColumns -join ', ').")
            return [pscustomobject]@{ Items = @(); Errors = $errors.ToArray() }
        }
        $unknownColumns = @($actualColumns | Where-Object { $_ -notin $requiredColumns })
        $controlColumns = @('Action', 'LicenseType', 'Environment', 'AcceptBackBilling', 'AcceptLicenseTypeChange', 'ConfirmNonProductionCoverage', 'ConfirmExternalPrerequisites')
        $unsafeColumns = @($unknownColumns | Where-Object { Test-BillingControlLikeColumn -Column $_ -KnownColumns $controlColumns })
        if ($unsafeColumns.Count -gt 0) {
            $errors.Add("CSV contains unsupported columns that resemble billing acknowledgement or control fields: $($unsafeColumns -join ', ').")
            return [pscustomobject]@{ Items = @(); Errors = $errors.ToArray() }
        }
        foreach ($column in $unknownColumns) {
            Write-Warning "Ignoring unrelated CSV column '$column'."
        }
    }

    $seen = @{}
    for ($index = 0; $index -lt $sourceRows.Count; $index++) {
        $row = $sourceRows[$index]
        $rowNumber = $index + 2
        $effectiveSubscription = if ([string]::IsNullOrWhiteSpace([string]$row.SubscriptionId)) {
            $DefaultSubscriptionId
        } else {
            ([string]$row.SubscriptionId).Trim()
        }
        $effectiveResourceGroup = ([string]$row.ServerResourceGroupName).Trim()
        $effectiveMachine = ([string]$row.ARCServerName).Trim()
        $effectiveAction = ([string]$row.Action).Trim()
        $effectiveLicenseType = ConvertTo-CanonicalLicenseType -Value ([string]$row.LicenseType).Trim()
        $effectiveEnvironment = ([string]$row.Environment).Trim()
        $rowErrors = [System.Collections.Generic.List[string]]::new()

        if (-not (Test-SubscriptionId $effectiveSubscription)) { $rowErrors.Add('SubscriptionId must be a valid GUID supplied by the row or command.') }
        if (-not (Test-ResourceGroupName $effectiveResourceGroup)) { $rowErrors.Add('ServerResourceGroupName is invalid.') }
        if (-not (Test-MachineName $effectiveMachine)) { $rowErrors.Add('ARCServerName must be 1-54 supported characters.') }
        if ($effectiveAction -notin @('Enable', 'Disable')) { $rowErrors.Add('Action must be Enable or Disable.') }

        $backBilling = $null
        $licenseChange = $null
        $nonProductionCoverage = $null
        $externalPrerequisites = $null
        foreach ($booleanField in @('AcceptBackBilling', 'AcceptLicenseTypeChange', 'ConfirmNonProductionCoverage', 'ConfirmExternalPrerequisites')) {
            try {
                $parsed = ConvertTo-StrictBoolean -Value $row.$booleanField -AllowEmpty
                switch ($booleanField) {
                    'AcceptBackBilling' { $backBilling = $parsed }
                    'AcceptLicenseTypeChange' { $licenseChange = $parsed }
                    'ConfirmNonProductionCoverage' { $nonProductionCoverage = $parsed }
                    'ConfirmExternalPrerequisites' { $externalPrerequisites = $parsed }
                }
            } catch {
                $rowErrors.Add("$booleanField $($_.Exception.Message)")
            }
        }

        if ($effectiveAction -eq 'Enable') {
            if ($effectiveLicenseType -and $effectiveLicenseType -notin @('Paid', 'PAYG')) { $rowErrors.Add('LicenseType must be empty, Paid, or PAYG for Enable.') }
            if ($effectiveEnvironment -notin @('Production', 'NonProduction')) { $rowErrors.Add('Environment must be Production or NonProduction for Enable.') }
            if ($backBilling -ne $true) { $rowErrors.Add('AcceptBackBilling must be TRUE for Enable.') }
            if ($externalPrerequisites -ne $true) { $rowErrors.Add('ConfirmExternalPrerequisites must be TRUE for Enable.') }
        } elseif ($effectiveAction -eq 'Disable') {
            $enableOnlyValues = @(
                $effectiveLicenseType, $effectiveEnvironment, [string]$row.AcceptBackBilling,
                [string]$row.AcceptLicenseTypeChange, [string]$row.ConfirmNonProductionCoverage,
                [string]$row.ConfirmExternalPrerequisites
            )
            if ($enableOnlyValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
                $rowErrors.Add('Disable requires LicenseType, Environment, and all enable-only acknowledgements to be empty.')
            }
        }

        $resourceId = "/subscriptions/$effectiveSubscription/resourceGroups/$effectiveResourceGroup/providers/Microsoft.HybridCompute/machines/$effectiveMachine"
        $key = $resourceId.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            $rowErrors.Add("Duplicate or contradictory machine target; first specified on row $($seen[$key]).")
        } else {
            $seen[$key] = $rowNumber
        }

        if ($rowErrors.Count -gt 0) {
            $errors.Add("Row ${rowNumber}: $($rowErrors -join ' ')")
            continue
        }

        $items.Add([pscustomobject][ordered]@{
            RowNumber = $rowNumber
            SubscriptionId = $effectiveSubscription
            ServerResourceGroupName = $effectiveResourceGroup
            ARCServerName = $effectiveMachine
            MachineResourceId = $resourceId
            Action = $effectiveAction
            LicenseType = $effectiveLicenseType
            Environment = $effectiveEnvironment
            AcceptBackBilling = $backBilling -eq $true
            AcceptLicenseTypeChange = $licenseChange -eq $true
            ConfirmNonProductionCoverage = $nonProductionCoverage -eq $true
            ConfirmExternalPrerequisites = $externalPrerequisites -eq $true
        })
    }

    return [pscustomobject]@{ Items = $items.ToArray(); Errors = $errors.ToArray() }
}

function Get-BearerToken {
    param(
        [object]$TokenObject,
        [string]$Tenant,
        [string]$ApplicationId,
        [string]$Secret
    )

    if ($null -ne $TokenObject) {
        if ($Tenant -or $ApplicationId -or $Secret) { throw 'Provide either userToken or the complete service principal credentials, not both.' }
        if ($null -eq $TokenObject.ExpiresOn -or $TokenObject.ExpiresOn -le (Get-Date)) { throw 'The provided user token is expired or has no valid expiration time.' }
        if ($null -eq $TokenObject.Token) { throw 'The provided user token object has no Token value.' }
        if ($TokenObject.Token -is [securestring]) { return ConvertFrom-SecureString -SecureString $TokenObject.Token -AsPlainText }
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
    $response = Invoke-WebRequest -Method Post -Uri "$($script:Configuration.LoginEndpoint)/$Tenant/oauth2/token" `
        -ContentType 'application/x-www-form-urlencoded' -Body $authBody -ErrorAction Stop
    $authResponse = $response.Content | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$authResponse.access_token)) { throw 'Authentication response did not contain an access token.' }
    return [string]$authResponse.access_token
}

function Get-HeaderValue {
    param([object]$Headers, [string[]]$Names)

    if ($null -eq $Headers) { return $null }
    foreach ($name in $Names) {
        if ($Headers -is [System.Collections.IDictionary]) {
            foreach ($key in $Headers.Keys) {
                if ([string]$key -ieq $name) { return [string]$Headers[$key] }
            }
        } elseif ($null -ne $Headers.PSObject.Properties[$name]) {
            return [string]$Headers.$name
        }
    }
    return $null
}

function Get-RetryDelaySeconds {
    param([object]$Headers, [int]$DefaultSeconds)

    $seconds = 0
    $retryAfter = Get-HeaderValue -Headers $Headers -Names @('Retry-After')
    if ([int]::TryParse($retryAfter, [ref]$seconds) -and $seconds -ge 0) { return [math]::Min($seconds, 60) }
    $milliseconds = 0
    $retryAfterMilliseconds = Get-HeaderValue -Headers $Headers -Names @('x-ms-retry-after-ms')
    if ([int]::TryParse($retryAfterMilliseconds, [ref]$milliseconds) -and $milliseconds -ge 0) {
        return [math]::Min([int][math]::Ceiling($milliseconds / 1000), 60)
    }
    return [math]::Min([math]::Max($DefaultSeconds, 0), 60)
}

function Assert-TrustedArmUri {
    param([string]$Uri, [string]$Purpose)

    $parsed = $null
    $arm = [uri]$script:Configuration.ArmEndpoint
    if (-not [uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed) -or
        $parsed.Scheme -ine 'https' -or $parsed.Host -ine $arm.Host -or
        -not [string]::IsNullOrWhiteSpace($parsed.UserInfo)) {
        throw "ARM returned an untrusted $Purpose URL."
    }
}

function Invoke-ArmRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT')][string]$Method,
        [Parameter(Mandatory)][hashtable]$Headers,
        [string]$Body
    )

    $parameters = @{
        Uri = $Uri
        Method = $Method
        Headers = $Headers
        ErrorAction = 'Stop'
        SkipHttpErrorCheck = $true
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $parameters.Body = $Body
        $parameters.ContentType = 'application/json'
    }

    $transient = @(408, 429, 500, 502, 503, 504)
    for ($attempt = 1; $attempt -le $script:Configuration.RequestAttempts; $attempt++) {
        $response = Invoke-WebRequest @parameters
        if ([int]$response.StatusCode -notin $transient -or $attempt -eq $script:Configuration.RequestAttempts) { break }
        $fallbackSeconds = [int][math]::Min($script:Configuration.RequestRetryIntervalSeconds * [math]::Pow(2, $attempt - 1), 60)
        Start-Sleep -Seconds (Get-RetryDelaySeconds -Headers $response.Headers -DefaultSeconds $fallbackSeconds)
    }

    $content = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$response.Content)) {
        try { $content = $response.Content | ConvertFrom-Json -Depth 100 }
        catch { throw "ARM returned invalid JSON for $Method $Uri." }
    }
    if ($null -ne $content -and $null -ne $content.PSObject.Properties['nextLink'] -and
        -not [string]::IsNullOrWhiteSpace([string]$content.nextLink)) {
        Assert-TrustedArmUri -Uri ([string]$content.nextLink) -Purpose 'nextLink'
    }
    return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Headers = $response.Headers; Content = $content }
}

function Get-MachineUri {
    param([pscustomobject]$Item)

    $resourceGroup = [uri]::EscapeDataString($Item.ServerResourceGroupName)
    $machine = [uri]::EscapeDataString($Item.ARCServerName)
    return "$($script:Configuration.ArmEndpoint)/subscriptions/$($Item.SubscriptionId)/resourceGroups/$resourceGroup/providers/Microsoft.HybridCompute/machines/$machine`?api-version=$($script:Configuration.MachineApiVersion)"
}

function Get-ExtensionUri {
    param([pscustomobject]$Item)

    $resourceGroup = [uri]::EscapeDataString($Item.ServerResourceGroupName)
    $machine = [uri]::EscapeDataString($Item.ARCServerName)
    return "$($script:Configuration.ArmEndpoint)/subscriptions/$($Item.SubscriptionId)/resourceGroups/$resourceGroup/providers/Microsoft.HybridCompute/machines/$machine/extensions/$($script:Configuration.ExtensionName)`?api-version=$($script:Configuration.ExtensionApiVersion)"
}

function Get-ObjectValue {
    param([AllowNull()][object]$InputObject, [string[]]$Paths)

    foreach ($path in $Paths) {
        $value = $InputObject
        foreach ($segment in $path.Split('.')) {
            if ($null -eq $value -or $null -eq $value.PSObject.Properties[$segment]) { $value = $null; break }
            $value = $value.$segment
        }
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { return $value }
    }
    return $null
}

function ConvertTo-NormalizedResourceId {
    param([string]$ResourceId)

    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return '' }
    return $ResourceId.Trim().TrimEnd('/').ToLowerInvariant()
}

function Assert-ExpectedExtensionIdentity {
    param([pscustomobject]$Item, [object]$Extension)

    $expectedId = "$($Item.MachineResourceId)/extensions/$($script:Configuration.ExtensionName)"
    if ((ConvertTo-NormalizedResourceId ([string]$Extension.id)) -ne (ConvertTo-NormalizedResourceId $expectedId) -or
        [string]$Extension.name -cne $script:Configuration.ExtensionName -or
        [string]$Extension.properties.publisher -ine $script:Configuration.ExtensionPublisher -or
        [string]$Extension.properties.type -ine $script:Configuration.ExtensionName) {
        throw 'The returned extension identity, publisher, or type does not match the expected WindowsAgent.SqlServer resource.'
    }
}

function Get-AllSqlInstances {
    param([string]$Subscription, [hashtable]$Headers)

    $instances = [System.Collections.Generic.List[object]]::new()
    $nextLink = "$($script:Configuration.ArmEndpoint)/subscriptions/$Subscription/providers/Microsoft.AzureArcData/sqlServerInstances`?api-version=$($script:Configuration.SqlInstanceApiVersion)"
    while (-not [string]::IsNullOrWhiteSpace($nextLink)) {
        $response = Invoke-ArmRequest -Uri $nextLink -Method GET -Headers $Headers
        if ($response.StatusCode -ne 200) { throw "SQL instance list failed (HTTP $($response.StatusCode))." }
        foreach ($instance in @($response.Content.value)) { $instances.Add($instance) }
        $nextLink = [string]$response.Content.nextLink
    }
    return $instances.ToArray()
}

function Get-InstanceFacts {
    param([object]$Instance)

    $version = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.version', 'properties.currentVersion', 'properties.productVersion'))
    $edition = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.edition', 'properties.currentEdition'))
    $eligibleVersion = if ($version -match '(?i)SQL\s*Server\s*2014|^12(\.|$)') { 'SQL Server 2014' } elseif ($version -match '(?i)SQL\s*Server\s*2016|^13(\.|$)') { 'SQL Server 2016' } else { $null }
    $editionKind = if ($edition -match '(?i)\b(Standard|Enterprise)\b') { 'Production' } elseif ($edition -match '(?i)\bDeveloper\b') { 'Developer' } else { 'Unsupported' }
    return [pscustomobject][ordered]@{
        Name = [string]$Instance.name
        Version = $version
        EligibleVersion = $eligibleVersion
        Edition = $edition
        EditionKind = $editionKind
        ServiceType = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.serviceType'))
        HostType = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.hostType', 'properties.hostingType'))
        DetectedCores = Get-ObjectValue -InputObject $Instance -Paths @('properties.vCore', 'properties.vCores', 'properties.coreCount', 'properties.cores', 'properties.hostResources.logicalCores')
        InventoryTimestamp = Get-ObjectValue -InputObject $Instance -Paths @('properties.lastInventoryUploadTime')
        UsageTimestamp = Get-ObjectValue -InputObject $Instance -Paths @('properties.lastUsageUploadTime')
        PassiveStatus = Get-ObjectValue -InputObject $Instance -Paths @('properties.isPassive', 'properties.passiveStatus', 'properties.licenseDetails.isPassive')
    }
}

function Get-Freshness {
    param([object[]]$Instances, [ValidateSet('InventoryTimestamp', 'UsageTimestamp')][string]$PropertyName)

    if ($Instances.Count -eq 0) { return 'Missing' }
    foreach ($instance in $Instances) {
        $value = $instance.$PropertyName
        $timestamp = [datetime]::MinValue
        if ($null -eq $value -or -not [datetime]::TryParse([string]$value, [ref]$timestamp)) { return 'Missing' }
        if ($timestamp.ToUniversalTime() -lt [datetime]::UtcNow.AddHours(-24)) { return 'Stale' }
    }
    return 'Fresh'
}

function Test-ProviderRegistration {
    param([string]$Subscription, [string]$Namespace, [hashtable]$Headers)

    $uri = "$($script:Configuration.ArmEndpoint)/subscriptions/$Subscription/providers/$Namespace`?api-version=$($script:Configuration.ProviderApiVersion)"
    $response = Invoke-ArmRequest -Uri $uri -Method GET -Headers $Headers
    if ($response.StatusCode -ne 200) { throw "Unable to read provider '$Namespace' registration (HTTP $($response.StatusCode))." }
    if ([string]$response.Content.registrationState -ine 'Registered') { throw "Provider '$Namespace' is not registered." }
    return $response.Content
}

function Get-PreflightRecord {
    param([pscustomobject]$Item, [hashtable]$Headers, [hashtable]$ProviderCache, [hashtable]$InstanceCache)

    if ($Item.Action -eq 'Disable') {
        $extensionResponse = Invoke-ArmRequest -Uri (Get-ExtensionUri $Item) -Method GET -Headers $Headers
        if ($extensionResponse.StatusCode -ne 200) { throw "WindowsAgent.SqlServer extension GET failed (HTTP $($extensionResponse.StatusCode))." }
        $extension = $extensionResponse.Content
        Assert-ExpectedExtensionIdentity -Item $Item -Extension $extension
        if ($null -eq $extension.properties.settings) { throw 'The expected extension did not return readable public settings to preserve.' }

        $warnings = [System.Collections.Generic.List[string]]::new()
        if ([string]$extension.properties.provisioningState -ine 'Succeeded') {
            $warnings.Add("Cancellation is proceeding with degraded extension health evidence: provisioning state is '$($extension.properties.provisioningState)'.")
        }
        if ([string]::IsNullOrWhiteSpace([string]$extension.properties.typeHandlerVersion) -or
            [string]$extension.properties.typeHandlerVersion -notin $script:Configuration.SupportedExtensionVersions) {
            $warnings.Add("Cancellation is proceeding with unavailable or unsupported extension version evidence: '$($extension.properties.typeHandlerVersion)'.")
        }
        try {
            if ((ConvertTo-StrictBoolean -Value $extension.properties.settings.SqlManagement.IsEnabled) -ne $true) {
                $warnings.Add('Cancellation is proceeding without positive SqlManagement.IsEnabled evidence.')
            }
        } catch {
            $warnings.Add('Cancellation is proceeding because SqlManagement.IsEnabled evidence is unavailable.')
        }

        $currentState = ConvertTo-StrictBoolean -Value $extension.properties.settings.enableExtendedSecurityUpdates -AllowEmpty
        $currentLicense = ConvertTo-CanonicalLicenseType -Value $extension.properties.settings.LicenseType
        return [pscustomobject][ordered]@{
            Item = $Item
            Machine = $null
            Extension = $extension
            Instances = @()
            CurrentState = $currentState
            DesiredState = $false
            CurrentLicenseType = $currentLicense
            DesiredLicenseType = $currentLicense
            LicenseChangeRequested = $false
            HostType = ''
            DetectedCores = $null
            EligibleVersions = @()
            Editions = @()
            InstanceNames = @()
            ServiceTypes = @()
            InventoryFreshness = 'UnavailableForCancellation'
            UsageFreshness = 'UnavailableForCancellation'
            Warnings = $warnings.ToArray()
        }
    }

    if (-not $ProviderCache.ContainsKey($Item.SubscriptionId)) {
        $hybrid = Test-ProviderRegistration -Subscription $Item.SubscriptionId -Namespace 'Microsoft.HybridCompute' -Headers $Headers
        $arcData = Test-ProviderRegistration -Subscription $Item.SubscriptionId -Namespace 'Microsoft.AzureArcData' -Headers $Headers
        $ProviderCache[$Item.SubscriptionId] = [pscustomobject]@{ Hybrid = $hybrid; ArcData = $arcData }
    }

    $machineResponse = Invoke-ArmRequest -Uri (Get-MachineUri $Item) -Method GET -Headers $Headers
    if ($machineResponse.StatusCode -ne 200) { throw "Arc machine GET failed (HTTP $($machineResponse.StatusCode))." }
    $machine = $machineResponse.Content
    $connection = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.status', 'properties.connectionStatus'))
    $mode = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.agentConfiguration.mode'))
    $operatingSystem = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.osName', 'properties.osType'))
    $cloudProvider = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.detectedProperties.cloudProvider', 'properties.cloudMetadataProvider'))
    if ($connection -ine 'Connected') { throw "Arc machine is not connected. Status: '$connection'." }
    if ($mode -ine 'Full') { throw "Arc machine agent mode must be Full. Mode: '$mode'." }
    if ($operatingSystem -notmatch '(?i)Windows') { throw "Arc machine must report Windows. Operating system: '$operatingSystem'." }
    if ($cloudProvider -ieq 'Azure') { throw 'Native Azure virtual machines must use the SQL IaaS Agent extension.' }
    if ([string]::IsNullOrWhiteSpace([string]$machine.location)) { throw 'Arc machine response has no location.' }

    $sqlType = @($ProviderCache[$Item.SubscriptionId].ArcData.resourceTypes | Where-Object { $_.resourceType -ieq 'sqlServerInstances' }) | Select-Object -First 1
    if ($null -eq $sqlType -or @($sqlType.locations).Count -eq 0) { throw 'SQL regional capability is indeterminate.' }
    $normalizedLocation = ([string]$machine.location -replace '\s', '').ToLowerInvariant()
    $supportedLocations = @($sqlType.locations | ForEach-Object { ([string]$_ -replace '\s', '').ToLowerInvariant() })
    if ($normalizedLocation -notin $supportedLocations) { throw "Machine location '$($machine.location)' is not supported for Arc SQL inventory." }

    $extensionResponse = Invoke-ArmRequest -Uri (Get-ExtensionUri $Item) -Method GET -Headers $Headers
    if ($extensionResponse.StatusCode -ne 200) { throw "WindowsAgent.SqlServer extension GET failed (HTTP $($extensionResponse.StatusCode))." }
    $extension = $extensionResponse.Content
    Assert-ExpectedExtensionIdentity -Item $Item -Extension $extension
    if ([string]$extension.properties.provisioningState -ine 'Succeeded') { throw "SQL extension provisioning state is '$($extension.properties.provisioningState)', not Succeeded." }
    if ([string]$extension.properties.typeHandlerVersion -notin $script:Configuration.SupportedExtensionVersions) { throw "SQL extension version '$($extension.properties.typeHandlerVersion)' is outside the supported release baseline." }
    if ((ConvertTo-StrictBoolean -Value $extension.properties.settings.SqlManagement.IsEnabled) -ne $true) { throw 'SqlManagement.IsEnabled is not true.' }

    if (-not $InstanceCache.ContainsKey($Item.SubscriptionId)) {
        $InstanceCache[$Item.SubscriptionId] = @(Get-AllSqlInstances -Subscription $Item.SubscriptionId -Headers $Headers)
    }
    $instances = @($InstanceCache[$Item.SubscriptionId] | Where-Object {
        (ConvertTo-NormalizedResourceId (Get-ObjectValue -InputObject $_ -Paths @('properties.containerResourceId'))) -eq
            (ConvertTo-NormalizedResourceId $Item.MachineResourceId)
    } | ForEach-Object { Get-InstanceFacts -Instance $_ })

    $warnings = [System.Collections.Generic.List[string]]::new()
    $inventoryFreshness = Get-Freshness -Instances $instances -PropertyName InventoryTimestamp
    $usageFreshness = Get-Freshness -Instances $instances -PropertyName UsageTimestamp
    if ($inventoryFreshness -ne 'Fresh') { $warnings.Add("Inventory timestamp is $inventoryFreshness; eligibility is uncertain, but staleness alone does not block the operation.") }
    if ($usageFreshness -ne 'Fresh') { $warnings.Add("Usage timestamp is $usageFreshness; eligibility is uncertain, but staleness alone does not block the operation.") }
    $eligibleVersions = @($instances | Where-Object EligibleVersion | ForEach-Object EligibleVersion | Select-Object -Unique)
    if ($eligibleVersions.Count -gt 1) { $warnings.Add('SQL Server 2014 and SQL Server 2016 are both present; each version can produce a separate ESU meter.') }
    if ($instances | Where-Object { $null -ne $_.PassiveStatus }) { $warnings.Add('Passive/DR state is extension-reported and does not independently prove free coverage.') }

    $currentLicense = ConvertTo-CanonicalLicenseType -Value $extension.properties.settings.LicenseType
    $effectiveLicense = if ($Item.Action -eq 'Enable' -and $Item.LicenseType) { $Item.LicenseType } else { $currentLicense }
    $currentState = ConvertTo-StrictBoolean -Value $extension.properties.settings.enableExtendedSecurityUpdates -AllowEmpty
    if ($null -eq $currentState) { $currentState = $false }
    $desiredState = $Item.Action -eq 'Enable'
    $licenseChangeRequested = $Item.Action -eq 'Enable' -and $Item.LicenseType -and $Item.LicenseType -cne $currentLicense

    if ($Item.Action -eq 'Enable') {
        if ($effectiveLicense -notin @('Paid', 'PAYG')) { throw "Effective LicenseType '$effectiveLicense' is not eligible for Arc-enabled SQL Server ESUs." }
        if ($licenseChangeRequested -and -not $Item.AcceptLicenseTypeChange) { throw "AcceptLicenseTypeChange must be TRUE because LicenseType would change from '$currentLicense' to '$effectiveLicense'." }
        if ($instances.Count -eq 0) { throw 'No SQL Server inventory was discovered for the Arc machine.' }
        $unsupportedVersions = @($instances | Where-Object { -not $_.EligibleVersion })
        if ($unsupportedVersions.Count -gt 0) { throw "Unsupported SQL Server version detected: $(@($unsupportedVersions | ForEach-Object Version | Select-Object -Unique) -join ', ')." }
        $unsupportedEditions = @($instances | Where-Object EditionKind -eq 'Unsupported')
        if ($unsupportedEditions.Count -gt 0) { throw "Unsupported SQL Server edition detected: $(@($unsupportedEditions | ForEach-Object Edition | Select-Object -Unique) -join ', ')." }
        $developerInstances = @($instances | Where-Object EditionKind -eq 'Developer')
        if ($developerInstances.Count -gt 0 -and $Item.Environment -eq 'Production') { throw 'Developer edition cannot establish production ESU entitlement.' }
        if ($developerInstances.Count -gt 0 -and $Item.Environment -eq 'NonProduction' -and -not $Item.ConfirmNonProductionCoverage) {
            throw 'ConfirmNonProductionCoverage must be TRUE for nonproduction Developer edition.'
        }
    }

    return [pscustomobject][ordered]@{
        Item = $Item
        Machine = $machine
        Extension = $extension
        Instances = $instances
        CurrentState = $currentState
        DesiredState = $desiredState
        CurrentLicenseType = $currentLicense
        DesiredLicenseType = $effectiveLicense
        LicenseChangeRequested = $licenseChangeRequested
        HostType = [string]($instances | ForEach-Object HostType | Where-Object { $_ } | Select-Object -First 1)
        DetectedCores = ($instances | ForEach-Object DetectedCores | Where-Object { $null -ne $_ } | Select-Object -First 1)
        EligibleVersions = $eligibleVersions
        Editions = @($instances | ForEach-Object Edition | Select-Object -Unique)
        InstanceNames = @($instances | ForEach-Object Name)
        ServiceTypes = @($instances | ForEach-Object ServiceType)
        InventoryFreshness = $inventoryFreshness
        UsageFreshness = $usageFreshness
        Warnings = $warnings.ToArray()
    }
}

function Copy-JsonObject {
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject) { return [pscustomobject]@{} }
    return $InputObject | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json -Depth 100
}

function Add-OrReplaceObjectProperty {
    param([object]$InputObject, [string]$Name, [AllowNull()][object]$Value)

    if ($null -ne $InputObject.PSObject.Properties[$Name]) { $InputObject.$Name = $Value }
    else { $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function ConvertTo-ExtensionRequestBody {
    param([pscustomobject]$Preflight, [string]$Timestamp)

    $extension = $Preflight.Extension
    $settings = Copy-JsonObject -InputObject $extension.properties.settings
    Add-OrReplaceObjectProperty -InputObject $settings -Name 'enableExtendedSecurityUpdates' -Value ([bool]$Preflight.DesiredState)
    Add-OrReplaceObjectProperty -InputObject $settings -Name 'esuLastUpdatedTimestamp' -Value $Timestamp
    if (-not [string]::IsNullOrWhiteSpace([string]$Preflight.DesiredLicenseType)) {
        Add-OrReplaceObjectProperty -InputObject $settings -Name 'LicenseType' -Value (ConvertTo-CanonicalLicenseType -Value $Preflight.DesiredLicenseType)
    }

    $properties = [ordered]@{
        publisher = [string]$extension.properties.publisher
        type = [string]$extension.properties.type
    }
    foreach ($name in @('typeHandlerVersion', 'autoUpgradeMinorVersion', 'enableAutomaticUpgrade', 'forceUpdateTag')) {
        if ($null -ne $extension.properties.PSObject.Properties[$name]) { $properties[$name] = $extension.properties.$name }
    }
    $properties.settings = $settings
    return ([ordered]@{ location = [string]$extension.location; properties = $properties } | ConvertTo-Json -Depth 100 -Compress)
}

function Get-ComparableSettings {
    param([object]$Settings)

    $copy = Copy-JsonObject -InputObject $Settings
    foreach ($name in @('enableExtendedSecurityUpdates', 'esuLastUpdatedTimestamp', 'LicenseType')) {
        if ($null -ne $copy.PSObject.Properties[$name]) { $copy.PSObject.Properties.Remove($name) }
    }
    return $copy
}

function Test-JsonSemanticEqual {
    param([AllowNull()][object]$Left, [AllowNull()][object]$Right)

    if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
    $leftIsObject = $Left -is [pscustomobject] -or $Left -is [System.Collections.IDictionary]
    $rightIsObject = $Right -is [pscustomobject] -or $Right -is [System.Collections.IDictionary]
    if ($leftIsObject -or $rightIsObject) {
        if (-not ($leftIsObject -and $rightIsObject)) { return $false }
        $leftProperties = if ($Left -is [System.Collections.IDictionary]) { @($Left.Keys) } else { @($Left.PSObject.Properties.Name) }
        $rightProperties = if ($Right -is [System.Collections.IDictionary]) { @($Right.Keys) } else { @($Right.PSObject.Properties.Name) }
        if ($leftProperties.Count -ne $rightProperties.Count) { return $false }
        foreach ($name in $leftProperties) {
            if ($name -cnotin $rightProperties) { return $false }
            $leftValue = if ($Left -is [System.Collections.IDictionary]) { $Left[$name] } else { $Left.$name }
            $rightValue = if ($Right -is [System.Collections.IDictionary]) { $Right[$name] } else { $Right.$name }
            if (-not (Test-JsonSemanticEqual -Left $leftValue -Right $rightValue)) { return $false }
        }
        return $true
    }
    $leftIsArray = $Left -is [System.Collections.IEnumerable] -and $Left -isnot [string]
    $rightIsArray = $Right -is [System.Collections.IEnumerable] -and $Right -isnot [string]
    if ($leftIsArray -or $rightIsArray) {
        if (-not ($leftIsArray -and $rightIsArray)) { return $false }
        $leftItems = @($Left)
        $rightItems = @($Right)
        if ($leftItems.Count -ne $rightItems.Count) { return $false }
        for ($index = 0; $index -lt $leftItems.Count; $index++) {
            if (-not (Test-JsonSemanticEqual -Left $leftItems[$index] -Right $rightItems[$index])) { return $false }
        }
        return $true
    }
    return $Left -ceq $Right
}

function Test-UtcTimestampEqual {
    param(
        [AllowNull()][object]$Actual,
        [string]$Expected
    )

    if ($Expected -notmatch '^20\d\d-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$' -or $null -eq $Actual) { return $false }
    $expectedTimestamp = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($Expected, [ref]$expectedTimestamp)) { return $false }
    if ($Actual -is [datetimeoffset]) {
        $actualTimestamp = [datetimeoffset]$Actual
    } elseif ($Actual -is [datetime]) {
        $actualTimestamp = [datetimeoffset]([datetime]$Actual).ToUniversalTime()
    } else {
        $actualTimestamp = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse([string]$Actual, [ref]$actualTimestamp)) { return $false }
    }
    return $actualTimestamp.ToUniversalTime() -eq $expectedTimestamp.ToUniversalTime()
}

function Wait-ArmOperation {
    param([string]$OperationUri, [hashtable]$Headers)

    for ($attempt = 1; $attempt -le $script:Configuration.PollAttempts; $attempt++) {
        $response = Invoke-ArmRequest -Uri $OperationUri -Method GET -Headers $Headers
        if ($response.StatusCode -notin @(200, 201, 202)) { throw "Asynchronous operation polling failed (HTTP $($response.StatusCode))." }
        $state = if ($response.Content.status) { [string]$response.Content.status } else { [string]$response.Content.properties.provisioningState }
        if ($state -ieq 'Succeeded') { return }
        if ($state -in @('Failed', 'Canceled', 'Cancelled')) { throw "Asynchronous operation finished with state '$state'." }
        if ($attempt -lt $script:Configuration.PollAttempts) {
            $fallbackSeconds = [int][math]::Min($script:Configuration.PollIntervalSeconds * [math]::Pow(2, $attempt - 1), 60)
            Start-Sleep -Seconds (Get-RetryDelaySeconds -Headers $response.Headers -DefaultSeconds $fallbackSeconds)
        }
    }
    throw "Asynchronous operation did not complete after $($script:Configuration.PollAttempts) polls."
}

function Wait-VerifiedExtension {
    param([pscustomobject]$Preflight, [string]$Timestamp, [hashtable]$Headers)

    $uri = Get-ExtensionUri $Preflight.Item
    $lastProblems = @()
    for ($attempt = 1; $attempt -le $script:Configuration.PollAttempts; $attempt++) {
        $response = Invoke-ArmRequest -Uri $uri -Method GET -Headers $Headers
        if ($response.StatusCode -ne 200) { throw "Final extension GET failed (HTTP $($response.StatusCode))." }
        $extension = $response.Content
        $state = [string]$extension.properties.provisioningState
        if ($state -in @('Failed', 'Canceled', 'Cancelled')) { throw "Extension provisioning finished with state '$state'." }
        if ($state -ieq 'Succeeded') {
            $problems = [System.Collections.Generic.List[string]]::new()
            $effectiveState = ConvertTo-StrictBoolean -Value $extension.properties.settings.enableExtendedSecurityUpdates -AllowEmpty
            if ($effectiveState -ne $Preflight.DesiredState) { $problems.Add('enableExtendedSecurityUpdates') }
            if (-not (Test-UtcTimestampEqual -Actual $extension.properties.settings.esuLastUpdatedTimestamp -Expected $Timestamp)) { $problems.Add('esuLastUpdatedTimestamp') }
            $actualLicenseType = ConvertTo-CanonicalLicenseType -Value $extension.properties.settings.LicenseType
            if ($actualLicenseType -cne $Preflight.DesiredLicenseType) { $problems.Add('LicenseType') }
            $before = Get-ComparableSettings -Settings $Preflight.Extension.properties.settings
            $after = Get-ComparableSettings -Settings $extension.properties.settings
            if (-not (Test-JsonSemanticEqual -Left $before -Right $after)) { $problems.Add('unrelated settings') }
            if ($problems.Count -eq 0) { return $extension }
            $lastProblems = $problems.ToArray()
        }
        if ($attempt -lt $script:Configuration.PollAttempts) {
            $fallbackSeconds = [int][math]::Min($script:Configuration.PollIntervalSeconds * [math]::Pow(2, $attempt - 1), 60)
            Start-Sleep -Seconds (Get-RetryDelaySeconds -Headers $response.Headers -DefaultSeconds $fallbackSeconds)
        }
    }
    if ($lastProblems.Count -gt 0) {
        throw "Final extension verification timed out after $($script:Configuration.PollAttempts) polls; settings did not converge for: $($lastProblems -join ', ')."
    }
    throw "Extension provisioning did not reach Succeeded after $($script:Configuration.PollAttempts) polls."
}

function Get-BillingPreview {
    param([pscustomobject]$Preflight)

    $item = $Preflight.Item
    $minimumStatement = if ($null -ne $Preflight.DetectedCores -and [int]$Preflight.DetectedCores -lt 4) { 'Azure applies a four-core minimum.' } else { 'The per-host meter has a four-core minimum.' }
    return "Machine=$($item.MachineResourceId); ESU=$($Preflight.CurrentState)->$($Preflight.DesiredState); LicenseType=$($Preflight.CurrentLicenseType)->$($Preflight.DesiredLicenseType); Environment=$($item.Environment); HostType=$($Preflight.HostType); DetectedCores=$($Preflight.DetectedCores); Instances=$($Preflight.InstanceNames -join ','); ServiceTypes=$($Preflight.ServiceTypes -join ','); Versions=$($Preflight.EligibleVersions -join ','); Editions=$($Preflight.Editions -join ','); $minimumStatement Current-year back-billing and re-enable/reconnection bill-back can apply. Cancellation stops future charges but removes future patch access. This operation does not enable automatic patching. This is per-host metering and does not establish pooled physical-core unlimited virtualization."
}

function Format-Result {
    param([pscustomobject]$Preflight, [string]$Status, [string]$Message, [bool]$Verified)

    return [pscustomobject][ordered]@{
        RowNumber = $Preflight.Item.RowNumber
        SubscriptionId = $Preflight.Item.SubscriptionId
        ResourceGroupName = $Preflight.Item.ServerResourceGroupName
        MachineName = $Preflight.Item.ARCServerName
        MachineResourceId = $Preflight.Item.MachineResourceId
        RequestedAction = $Preflight.Item.Action
        PreviousState = $Preflight.CurrentState
        DesiredState = $Preflight.DesiredState
        EffectiveState = if ($Status -in @('Succeeded', 'AlreadyCompliant')) { $Preflight.DesiredState } else { $Preflight.CurrentState }
        PreviousLicenseType = $Preflight.CurrentLicenseType
        DesiredLicenseType = $Preflight.DesiredLicenseType
        EffectiveLicenseType = if ($Status -in @('Succeeded', 'AlreadyCompliant')) { $Preflight.DesiredLicenseType } else { $Preflight.CurrentLicenseType }
        HostType = $Preflight.HostType
        DetectedCores = $Preflight.DetectedCores
        InstanceNames = $Preflight.InstanceNames -join ', '
        ServiceTypes = $Preflight.ServiceTypes -join ', '
        EligibleVersions = $Preflight.EligibleVersions -join ', '
        InventoryFreshness = $Preflight.InventoryFreshness
        UsageFreshness = $Preflight.UsageFreshness
        OperationStatus = $Status
        VerificationSucceeded = $Verified
        Message = $Message
    }
}

$plan = ConvertTo-PlanItems -ParameterSetName $PSCmdlet.ParameterSetName `
    -DefaultSubscriptionId $subscriptionId -ResourceGroupName $serverResourceGroupName `
    -MachineName $ARCServerName -RequestedAction $Action -RequestedLicenseType $LicenseType `
    -RequestedEnvironment $Environment -BackBillingAccepted $AcceptBackBilling.IsPresent `
    -LicenseTypeChangeAccepted $AcceptLicenseTypeChange.IsPresent `
    -NonProductionCoverageConfirmed $ConfirmNonProductionCoverage.IsPresent `
    -ExternalPrerequisitesConfirmed $ConfirmExternalPrerequisites.IsPresent -Path $csvFilePath

if ($plan.Errors.Count -gt 0) {
    foreach ($validationError in $plan.Errors) { Write-Error $validationError }
    Write-Host "Planned: $($plan.Items.Count); Succeeded: 0; Already compliant: 0; Previewed: 0; Declined: 0; Failed: $($plan.Errors.Count); Not started: 0"
    exit 1
}

try {
    $bearerToken = Get-BearerToken -TokenObject $userToken -Tenant $tenantId -ApplicationId $appID -Secret $clientSecret
} catch {
    Write-Error "Authentication failed: $($_.Exception.Message)"
    exit 1
}

$headers = @{ Authorization = "Bearer $bearerToken"; Accept = 'application/json' }
$preflightRecords = [System.Collections.Generic.List[object]]::new()
$preflightFailures = [System.Collections.Generic.List[object]]::new()
$providerCache = @{}
$instanceCache = @{}
foreach ($item in $plan.Items) {
    try {
        $preflight = Get-PreflightRecord -Item $item -Headers $headers -ProviderCache $providerCache -InstanceCache $instanceCache
        $preflightRecords.Add($preflight)
        foreach ($warning in $preflight.Warnings) { Write-Warning "$($item.MachineResourceId): $warning" }
        Write-Host (Get-BillingPreview -Preflight $preflight)
    } catch {
        $placeholder = [pscustomobject]@{
            Item = $item; CurrentState = $null; DesiredState = $item.Action -eq 'Enable'; CurrentLicenseType = $null
            DesiredLicenseType = $item.LicenseType; HostType = $null; DetectedCores = $null; EligibleVersions = @()
            InstanceNames = @(); ServiceTypes = @()
            InventoryFreshness = 'Unknown'; UsageFreshness = 'Unknown'
        }
        $preflightFailures.Add((Format-Result -Preflight $placeholder -Status 'Failed' -Message $_.Exception.Message -Verified $false))
    }
}

if ($preflightFailures.Count -gt 0) {
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($failure in $preflightFailures) { $results.Add($failure) }
    foreach ($record in $preflightRecords) {
        $results.Add((Format-Result -Preflight $record -Status 'NotStarted' -Message 'No changes were started because at least one target failed preflight.' -Verified $false))
    }
    $ordered = @($results | Sort-Object RowNumber)
    $ordered | Write-Output
    Write-Host "Planned: $($plan.Items.Count); Succeeded: 0; Already compliant: 0; Previewed: 0; Declined: 0; Failed: $(@($ordered | Where-Object OperationStatus -eq 'Failed').Count); Not started: $(@($ordered | Where-Object OperationStatus -eq 'NotStarted').Count)"
    exit 1
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($preflight in $preflightRecords) {
    $item = $preflight.Item
    if ($preflight.CurrentState -eq $preflight.DesiredState -and -not $preflight.LicenseChangeRequested) {
        $results.Add((Format-Result -Preflight $preflight -Status 'AlreadyCompliant' -Message 'The verified extension already has the requested state; no PUT was sent and the timestamp was unchanged.' -Verified $true))
        continue
    }
    if ($DryRun) {
        $results.Add((Format-Result -Preflight $preflight -Status 'Previewed' -Message 'Dry run completed after full read-only preflight; no PUT was sent.' -Verified $false))
        continue
    }

    $billingAction = Get-BillingPreview -Preflight $preflight
    if (-not $PSCmdlet.ShouldProcess($item.MachineResourceId, $billingAction)) {
        $status = if ($WhatIfPreference) { 'Previewed' } else { 'Declined' }
        $results.Add((Format-Result -Preflight $preflight -Status $status -Message 'No PUT was sent.' -Verified $false))
        continue
    }

    try {
        $timestamp = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $body = ConvertTo-ExtensionRequestBody -Preflight $preflight -Timestamp $timestamp
        $response = Invoke-ArmRequest -Uri (Get-ExtensionUri $item) -Method PUT -Headers $headers -Body $body
        if ($response.StatusCode -notin @(200, 201, 202)) { throw "Extension update failed (HTTP $($response.StatusCode))." }
        if ($response.StatusCode -eq 202) {
            $operationUri = Get-HeaderValue -Headers $response.Headers -Names @('Azure-AsyncOperation', 'Location')
            if ([string]::IsNullOrWhiteSpace($operationUri)) { throw 'Extension update returned 202 without an operation polling URL.' }
            Assert-TrustedArmUri -Uri $operationUri -Purpose 'operation polling'
            Wait-ArmOperation -OperationUri $operationUri -Headers $headers
        }
        Wait-VerifiedExtension -Preflight $preflight -Timestamp $timestamp -Headers $headers | Out-Null
        $results.Add((Format-Result -Preflight $preflight -Status 'Succeeded' -Message 'The SQL Server ESU host setting was updated and verified.' -Verified $true))
    } catch {
        $results.Add((Format-Result -Preflight $preflight -Status 'Failed' -Message $_.Exception.Message -Verified $false))
    }
}

$ordered = @($results | Sort-Object RowNumber)
$ordered | Write-Output
$succeeded = @($ordered | Where-Object OperationStatus -eq 'Succeeded').Count
$alreadyCompliant = @($ordered | Where-Object OperationStatus -eq 'AlreadyCompliant').Count
$previewed = @($ordered | Where-Object OperationStatus -eq 'Previewed').Count
$declined = @($ordered | Where-Object OperationStatus -eq 'Declined').Count
$failed = @($ordered | Where-Object OperationStatus -eq 'Failed').Count
$notStarted = @($ordered | Where-Object OperationStatus -eq 'NotStarted').Count
Write-Host "Planned: $($plan.Items.Count); Succeeded: $succeeded; Already compliant: $alreadyCompliant; Previewed: $previewed; Declined: $declined; Failed: $failed; Not started: $notStarted"

if ($failed -gt 0 -or $declined -gt 0 -or $notStarted -gt 0) { exit 1 }
exit 0