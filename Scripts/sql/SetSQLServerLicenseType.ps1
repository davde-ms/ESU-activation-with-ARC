<#
.SYNOPSIS
Sets the SQL Server LicenseType on an Arc-enabled Windows machine whose LicenseType is still empty.

.DESCRIPTION
WARNING: LicenseType is a licensing attestation (Paid) or an Azure billing decision for the SQL
Server software license (PAYG). It applies to every SQL Server instance on the host. Only the
license owner should choose it.

Updates the host-level WindowsAgent.SqlServer extension by using direct Azure Resource Manager
REST calls. The script only fills an empty (undefined, "Configuration needed") LicenseType; it
never overwrites an existing value. A host that already has the requested value is reported as
already compliant; a host with any other value fails preflight with no change.

All local input, including the required acknowledgement for the selected value, is validated
before authentication. Read-only preflight completes for every target before any change, and
the impact of the selected value is shown as warnings for every host:

- Paid requires -AttestSoftwareAssurance. When an Enterprise instance is reported, or when no SQL
  Server inventory is available, it also requires -ConfirmCoreBasedEnterpriseLicense because
  Microsoft states that Server+CAL licenses must use LicenseOnly.
- PAYG requires -AcceptPaygBilling. It starts hourly Azure billing for the SQL Server software
  license. -ConsentToRecurringPAYG additionally writes the ConsentToRecurringPAYG setting that
  CSP-managed subscriptions require; Microsoft states that it can't be changed without
  reinstalling the extension.
- LicenseOnly accepts no acknowledgement. The host isn't eligible for an Arc-enabled SQL Server
  ESU subscription.

The script preserves every other public extension setting and never changes the ESU setting. Use
SetSQLServerESUSubscription.ps1 separately to enable ESUs after the LicenseType is set.

.PARAMETER LicenseType
Paid, PAYG, or LicenseOnly. Written only when the host's current LicenseType is empty.

.PARAMETER AttestSoftwareAssurance
Required for Paid. Attests that the license owner has Enterprise or Standard core licenses with
active Software Assurance or an active SQL Server subscription for this host and that the device
complies with the Product Terms outsourcing restrictions.

.PARAMETER AcceptPaygBilling
Required for PAYG. Accepts hourly Azure billing for the SQL Server software license of the host.

.PARAMETER ConsentToRecurringPAYG
Valid only with PAYG, for CSP-managed subscriptions. Records ConsentToRecurringPAYG with the current
UTC time. It can't be changed without reinstalling the extension.

.PARAMETER ConfirmCoreBasedEnterpriseLicense
Valid only with Paid. Confirms that any Enterprise instance on the host is covered by a core-based
license rather than Server+CAL. Required when Enterprise is reported or inventory is unavailable.

.EXAMPLE
$token = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
./Scripts/sql/SetSQLServerLicenseType.ps1 -subscriptionId '00000000-0000-0000-0000-000000000001' `
    -serverResourceGroupName 'rg-arc-servers' -ARCServerName 'sql-host-01' -LicenseType Paid `
    -AttestSoftwareAssurance -userToken $token -DryRun

.EXAMPLE
./Scripts/sql/SetSQLServerLicenseType.ps1 -subscriptionId '00000000-0000-0000-0000-000000000001' `
    -csvFilePath 'C:\Temp\SetSQLServerLicenseType.csv' -userToken $token -WhatIf

.EXAMPLE
./Scripts/sql/SetSQLServerLicenseType.ps1 -subscriptionId '00000000-0000-0000-0000-000000000001' `
    -serverResourceGroupName 'rg-arc-servers' -ARCServerName 'sql-host-02' -LicenseType PAYG `
    -AcceptPaygBilling -tenantId '00000000-0000-0000-0000-000000000002' `
    -appID '00000000-0000-0000-0000-000000000003' -clientSecret $clientSecret -DryRun
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
    [ValidateSet('Paid', 'PAYG', 'LicenseOnly')]
    [string]$LicenseType,

    [Parameter(ParameterSetName = 'Single')]
    [switch]$AttestSoftwareAssurance,

    [Parameter(ParameterSetName = 'Single')]
    [switch]$AcceptPaygBilling,

    [Parameter(ParameterSetName = 'Single')]
    [switch]$ConsentToRecurringPAYG,

    [Parameter(ParameterSetName = 'Single')]
    [switch]$ConfirmCoreBasedEnterpriseLicense,

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
    PollAttempts = 12
    PollIntervalSeconds = 5
    RequestAttempts = 4
    RequestRetryIntervalSeconds = 2
}

$script:CsvColumns = @(
    'SubscriptionId', 'ServerResourceGroupName', 'ARCServerName', 'LicenseType',
    'AttestSoftwareAssurance', 'AcceptPaygBilling', 'ConsentToRecurringPAYG', 'ConfirmCoreBasedEnterpriseLicense'
)
$script:AcknowledgementColumns = @('AttestSoftwareAssurance', 'AcceptPaygBilling', 'ConsentToRecurringPAYG', 'ConfirmCoreBasedEnterpriseLicense')

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

    $text = ([string]$Value).Trim()
    foreach ($known in @('Paid', 'PAYG', 'LicenseOnly')) {
        if ($text -ieq $known) { return $known }
    }
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
    return $normalized -match '^(accept|confirm|attest|consent).*' -or $normalized -match 'licen|payg|billing'
}

function ConvertTo-PlanItem {
    param(
        [string]$ParameterSetName,
        [string]$DefaultSubscriptionId,
        [string]$ResourceGroupName,
        [string]$MachineName,
        [string]$RequestedLicenseType,
        [bool]$SoftwareAssuranceAttested,
        [bool]$PaygBillingAccepted,
        [bool]$RecurringPaygConsented,
        [bool]$CoreBasedEnterpriseConfirmed,
        [string]$Path
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $items = [System.Collections.Generic.List[object]]::new()

    if ($ParameterSetName -eq 'Single') {
        $sourceRows = @([pscustomobject]@{
            SubscriptionId = $DefaultSubscriptionId
            ServerResourceGroupName = $ResourceGroupName
            ARCServerName = $MachineName
            LicenseType = $RequestedLicenseType
            AttestSoftwareAssurance = if ($SoftwareAssuranceAttested) { 'TRUE' } else { '' }
            AcceptPaygBilling = if ($PaygBillingAccepted) { 'TRUE' } else { '' }
            ConsentToRecurringPAYG = if ($RecurringPaygConsented) { 'TRUE' } else { '' }
            ConfirmCoreBasedEnterpriseLicense = if ($CoreBasedEnterpriseConfirmed) { 'TRUE' } else { '' }
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

        $actualColumns = @($sourceRows[0].PSObject.Properties.Name)
        $missingColumns = @($script:CsvColumns | Where-Object { $_ -notin $actualColumns })
        if ($missingColumns.Count -gt 0) {
            $errors.Add("CSV is missing required columns: $($missingColumns -join ', ').")
            return [pscustomobject]@{ Items = @(); Errors = $errors.ToArray() }
        }
        $unknownColumns = @($actualColumns | Where-Object { $_ -notin $script:CsvColumns })
        $controlColumns = @('LicenseType') + $script:AcknowledgementColumns
        $unsafeColumns = @($unknownColumns | Where-Object { Test-BillingControlLikeColumn -Column $_ -KnownColumns $controlColumns })
        if ($unsafeColumns.Count -gt 0) {
            $errors.Add("CSV contains unsupported columns that resemble license or billing acknowledgement fields: $($unsafeColumns -join ', ').")
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
        $effectiveLicenseType = ConvertTo-CanonicalLicenseType -Value $row.LicenseType
        $rowErrors = [System.Collections.Generic.List[string]]::new()

        if (-not (Test-SubscriptionId $effectiveSubscription)) { $rowErrors.Add('SubscriptionId must be a valid GUID supplied by the row or command.') }
        if (-not (Test-ResourceGroupName $effectiveResourceGroup)) { $rowErrors.Add('ServerResourceGroupName is invalid.') }
        if (-not (Test-MachineName $effectiveMachine)) { $rowErrors.Add('ARCServerName must be 1-54 supported characters.') }
        if ($effectiveLicenseType -cnotin @('Paid', 'PAYG', 'LicenseOnly')) { $rowErrors.Add('LicenseType must be Paid, PAYG, or LicenseOnly.') }

        $acknowledgements = @{}
        foreach ($field in $script:AcknowledgementColumns) {
            try {
                $acknowledgements[$field] = (ConvertTo-StrictBoolean -Value $row.$field -AllowEmpty) -eq $true
            } catch {
                $acknowledgements[$field] = $false
                $rowErrors.Add("$field $($_.Exception.Message)")
            }
        }

        # Each acknowledgement belongs to exactly one license type so a copied row can't carry a
        # billing acceptance or attestation into a different licensing decision.
        switch ($effectiveLicenseType) {
            'Paid' {
                if (-not $acknowledgements.AttestSoftwareAssurance) { $rowErrors.Add('AttestSoftwareAssurance must be TRUE for Paid.') }
                if ($acknowledgements.AcceptPaygBilling) { $rowErrors.Add('AcceptPaygBilling is valid only for PAYG.') }
                if ($acknowledgements.ConsentToRecurringPAYG) { $rowErrors.Add('ConsentToRecurringPAYG is valid only for PAYG.') }
            }
            'PAYG' {
                if (-not $acknowledgements.AcceptPaygBilling) { $rowErrors.Add('AcceptPaygBilling must be TRUE for PAYG.') }
                if ($acknowledgements.AttestSoftwareAssurance) { $rowErrors.Add('AttestSoftwareAssurance is valid only for Paid.') }
                if ($acknowledgements.ConfirmCoreBasedEnterpriseLicense) { $rowErrors.Add('ConfirmCoreBasedEnterpriseLicense is valid only for Paid.') }
            }
            'LicenseOnly' {
                if ($acknowledgements.Values -contains $true) { $rowErrors.Add('LicenseOnly requires every acknowledgement to be empty or FALSE.') }
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
            LicenseType = $effectiveLicenseType
            AttestSoftwareAssurance = $acknowledgements.AttestSoftwareAssurance
            AcceptPaygBilling = $acknowledgements.AcceptPaygBilling
            ConsentToRecurringPAYG = $acknowledgements.ConsentToRecurringPAYG
            ConfirmCoreBasedEnterpriseLicense = $acknowledgements.ConfirmCoreBasedEnterpriseLicense
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

function Get-RetryDelaySecond {
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
        Start-Sleep -Seconds (Get-RetryDelaySecond -Headers $response.Headers -DefaultSeconds $fallbackSeconds)
    }

    $content = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$response.Content)) {
        try { $content = ConvertFrom-ArmJson -Json ([string]$response.Content) }
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

function Test-ProviderRegistration {
    param([string]$Subscription, [string]$Namespace, [hashtable]$Headers)

    $uri = "$($script:Configuration.ArmEndpoint)/subscriptions/$Subscription/providers/$Namespace`?api-version=$($script:Configuration.ProviderApiVersion)"
    $response = Invoke-ArmRequest -Uri $uri -Method GET -Headers $Headers
    if ($response.StatusCode -ne 200) { throw "Unable to read provider '$Namespace' registration (HTTP $($response.StatusCode))." }
    if ([string]$response.Content.registrationState -ine 'Registered') { throw "Provider '$Namespace' is not registered." }
}

function Get-AllSqlInstance {
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

function Get-InstanceFact {
    param([object]$Instance)

    return [pscustomobject][ordered]@{
        Name = [string]$Instance.name
        Version = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.version', 'properties.currentVersion'))
        Edition = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.edition'))
        HostType = [string](Get-ObjectValue -InputObject $Instance -Paths @('properties.hostType'))
        DetectedCores = Get-ObjectValue -InputObject $Instance -Paths @('properties.vCore', 'properties.cores')
    }
}

function Test-EmptyLicenseType {
    param([AllowNull()][object]$Settings)

    if ($null -eq $Settings -or $null -eq $Settings.PSObject.Properties['LicenseType']) { return $true }
    return [string]::IsNullOrWhiteSpace([string]$Settings.LicenseType)
}

function Get-PreflightRecord {
    param([pscustomobject]$Item, [hashtable]$Headers, [hashtable]$ProviderCache, [hashtable]$InstanceCache)

    if (-not $ProviderCache.ContainsKey($Item.SubscriptionId)) {
        Test-ProviderRegistration -Subscription $Item.SubscriptionId -Namespace 'Microsoft.HybridCompute' -Headers $Headers
        Test-ProviderRegistration -Subscription $Item.SubscriptionId -Namespace 'Microsoft.AzureArcData' -Headers $Headers
        $ProviderCache[$Item.SubscriptionId] = $true
    }

    $machineResponse = Invoke-ArmRequest -Uri (Get-MachineUri $Item) -Method GET -Headers $Headers
    if ($machineResponse.StatusCode -ne 200) { throw "Arc machine GET failed (HTTP $($machineResponse.StatusCode))." }
    $machine = $machineResponse.Content
    $connection = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.status'))
    $mode = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.agentConfiguration.configMode'))
    $operatingSystem = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.osName', 'properties.osType'))
    $cloudProvider = [string](Get-ObjectValue -InputObject $machine -Paths @('properties.detectedProperties.cloudProvider', 'properties.cloudMetadata.provider'))
    if ($connection -ine 'Connected') { throw "Arc machine is not connected. Status: '$connection'." }
    if ($mode -ine 'Full') { throw "Arc machine agent mode must be Full. Mode: '$mode'." }
    if ($operatingSystem -notmatch '(?i)Windows') { throw "Arc machine must report Windows. Operating system: '$operatingSystem'." }
    if ($cloudProvider -ieq 'Azure') { throw 'Native Azure virtual machines must use the SQL IaaS Agent extension.' }

    $extensionResponse = Invoke-ArmRequest -Uri (Get-ExtensionUri $Item) -Method GET -Headers $Headers
    if ($extensionResponse.StatusCode -ne 200) { throw "WindowsAgent.SqlServer extension GET failed (HTTP $($extensionResponse.StatusCode))." }
    $extension = $extensionResponse.Content
    Assert-ExpectedExtensionIdentity -Item $Item -Extension $extension
    if ([string]$extension.properties.provisioningState -ine 'Succeeded') { throw "SQL extension provisioning state is '$($extension.properties.provisioningState)', not Succeeded." }
    $settings = $extension.properties.settings
    if ($null -eq $settings) { throw 'The expected extension did not return readable public settings to preserve.' }

    $currentLicense = ConvertTo-CanonicalLicenseType -Value $settings.LicenseType
    $isEmpty = Test-EmptyLicenseType -Settings $settings
    $alreadyCompliant = $false
    if (-not $isEmpty) {
        if ($currentLicense -ceq $Item.LicenseType) {
            $alreadyCompliant = $true
        } else {
            throw "LicenseType on the host is already '$currentLicense'. This script only sets an empty LicenseType and never overwrites an existing value; no change was made."
        }
    }

    $esuEnabled = $false
    try { $esuEnabled = (ConvertTo-StrictBoolean -Value $settings.enableExtendedSecurityUpdates -AllowEmpty) -eq $true }
    catch { throw 'enableExtendedSecurityUpdates is not a readable Boolean; no change was made.' }
    if (-not $alreadyCompliant -and $Item.LicenseType -eq 'LicenseOnly' -and $esuEnabled) {
        throw 'ESU is enabled on this host; Microsoft requires the ESU subscription to be canceled before LicenseType can be set to LicenseOnly. No change was made.'
    }

    $existingConsent = $null -ne $settings.PSObject.Properties['ConsentToRecurringPAYG'] -and $null -ne $settings.ConsentToRecurringPAYG
    $writeConsent = -not $alreadyCompliant -and $Item.LicenseType -eq 'PAYG' -and $Item.ConsentToRecurringPAYG -and -not $existingConsent

    if (-not $InstanceCache.ContainsKey($Item.SubscriptionId)) {
        $InstanceCache[$Item.SubscriptionId] = @(Get-AllSqlInstance -Subscription $Item.SubscriptionId -Headers $Headers)
    }
    $instances = @($InstanceCache[$Item.SubscriptionId] | Where-Object {
        (ConvertTo-NormalizedResourceId (Get-ObjectValue -InputObject $_ -Paths @('properties.containerResourceId'))) -eq
            (ConvertTo-NormalizedResourceId $Item.MachineResourceId)
    } | ForEach-Object { Get-InstanceFact -Instance $_ })

    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($instances.Count -eq 0) {
        $warnings.Add('No SQL Server instance inventory was found for this machine, so the instances affected by this host-wide setting cannot be listed.')
    }
    # The ARM edition value doesn't distinguish Enterprise (Server+CAL) from Enterprise Core.
    $enterpriseInstances = @($instances | Where-Object { $_.Edition -match '(?i)\bEnterprise\b' })
    $enterpriseUnverifiable = $enterpriseInstances.Count -gt 0 -or $instances.Count -eq 0
    if (-not $alreadyCompliant -and $Item.LicenseType -eq 'Paid' -and $enterpriseUnverifiable -and -not $Item.ConfirmCoreBasedEnterpriseLicense) {
        $reason = if ($enterpriseInstances.Count -gt 0) { "Enterprise edition is reported for: $(@($enterpriseInstances | ForEach-Object Name) -join ', ')" } else { 'No SQL Server inventory is available to rule out Enterprise edition' }
        throw "$reason. Microsoft states that an Enterprise (non-Core) installation indicates Server+CAL, and Server+CAL must be LicenseOnly even with Software Assurance. Supply ConfirmCoreBasedEnterpriseLicense only if every Enterprise instance on this host is covered by a core-based license. No change was made."
    }
    if ($existingConsent -and $Item.LicenseType -eq 'PAYG' -and $Item.ConsentToRecurringPAYG) {
        $warnings.Add('ConsentToRecurringPAYG is already recorded on this extension and is left unchanged; Microsoft states that it can''t be changed without reinstalling the extension.')
    }
    if ($existingConsent -and $Item.LicenseType -ne 'PAYG') {
        $warnings.Add('ConsentToRecurringPAYG is already recorded on this extension and is left unchanged.')
    }
    $freeEditions = @($instances | Where-Object { $_.Edition -match '(?i)\b(Developer|Evaluation|Express)\b' })
    if ($instances.Count -gt 0 -and $freeEditions.Count -eq $instances.Count -and $Item.LicenseType -ne 'LicenseOnly') {
        $warnings.Add('Only free Developer, Evaluation, or Express editions are reported; Microsoft documents LicenseOnly for free editions.')
    }

    return [pscustomobject][ordered]@{
        Item = $Item
        Extension = $extension
        Instances = $instances
        CurrentLicenseType = if ($isEmpty) { '' } else { $currentLicense }
        AlreadyCompliant = $alreadyCompliant
        EsuEnabled = $esuEnabled
        WriteConsent = $writeConsent
        HostType = [string]($instances | ForEach-Object HostType | Where-Object { $_ } | Select-Object -First 1)
        DetectedCores = ($instances | ForEach-Object DetectedCores | Where-Object { $null -ne $_ } | Select-Object -First 1)
        Warnings = $warnings.ToArray()
    }
}

function Get-ImpactWarning {
    param([pscustomobject]$Preflight)

    $item = $Preflight.Item
    $instanceList = if ($Preflight.Instances.Count -gt 0) {
        @($Preflight.Instances | ForEach-Object { "$($_.Name) ($($_.Edition), $($_.Version))" }) -join '; '
    } else {
        'none reported'
    }
    $messages = [System.Collections.Generic.List[string]]::new()
    $messages.Add("HOST-WIDE: LicenseType '' -> '$($item.LicenseType)' applies to every SQL Server instance on this machine, not only out-of-support ones. Instances: $instanceList. HostType=$($Preflight.HostType); DetectedCores=$($Preflight.DetectedCores). This script never overwrites a LicenseType and doesn't enable ESUs.")
    switch ($item.LicenseType) {
        'Paid' {
            $messages.Add('ATTESTATION: By selecting Paid, the license owner attests that they have Enterprise or Standard licenses with active Software Assurance or an active SQL Server subscription license, and that the device complies with the Product Terms outsourcing restrictions. Server+CAL licenses must use LicenseOnly even with Software Assurance. An incorrect attestation is a licensing compliance issue.')
        }
        'PAYG' {
            $messages.Add('BILLING: PAYG starts hourly Azure billing for the SQL Server software license of this host, based on the cores the OSE can access with a four-core minimum, in addition to any ESU charges. Intermittent connectivity doesn''t stop PAYG billing; usage is reported when connectivity is restored. Stopping PAYG requires a separate LicenseType change that this script won''t make.')
            if ($Preflight.WriteConsent) {
                $messages.Add('RECURRING BILLING CONSENT: ConsentToRecurringPAYG (Consented=true, ConsentTimestamp=now UTC) will be recorded. Microsoft requires it for new PAYG in CSP-managed subscriptions; after that time, any disconnection longer than 30 days activates recurring PAYG billing (30-day backfill and ongoing hourly charges). It can''t be changed without reinstalling the extension.')
            } else {
                $messages.Add('CSP: Microsoft states that new PAYG isn''t allowed in CSP-managed subscriptions without recorded ConsentToRecurringPAYG. Stop and use ConsentToRecurringPAYG if this subscription is CSP-managed.')
            }
        }
        'LicenseOnly' {
            $messages.Add('ELIGIBILITY: A LicenseOnly host isn''t eligible for an Arc-enabled SQL Server ESU subscription, and features that require Software Assurance or PAYG aren''t available. Software usage is still reported according to Microsoft''s metering rules.')
        }
    }
    return $messages.ToArray()
}

function ConvertFrom-JsonElement {
    param([System.Text.Json.JsonElement]$Element)

    switch ($Element.ValueKind) {
        'Object' {
            $result = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) {
                if ($result.Contains($property.Name)) { throw "ARM returned JSON with duplicate property names that differ only by case: '$($property.Name)'." }
                $result[$property.Name] = ConvertFrom-JsonElement -Element $property.Value
            }
            return [pscustomobject]$result
        }
        'Array' {
            $items = [System.Collections.Generic.List[object]]::new()
            foreach ($child in $Element.EnumerateArray()) { $items.Add((ConvertFrom-JsonElement -Element $child)) }
            return , $items.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' {
            $integer = [long]0
            if ($Element.TryGetInt64([ref]$integer)) { return $integer }
            $decimal = [decimal]0
            if ($Element.TryGetDecimal([ref]$decimal)) { return $decimal }
            return $Element.GetDouble()
        }
        'True' { return $true }
        'False' { return $false }
        default { return $null }
    }
}

function ConvertFrom-ArmJson {
    param([string]$Json)

    # ConvertFrom-Json turns ISO-8601 strings into DateTime values on PowerShell 7.0-7.4, which would
    # rewrite the format or offset of date-like settings on the PUT. System.Text.Json keeps every
    # string exactly as ARM returned it on all PowerShell 7 versions.
    $options = [System.Text.Json.JsonDocumentOptions]@{ MaxDepth = 128 }
    $document = [System.Text.Json.JsonDocument]::Parse($Json, $options)
    try {
        return ConvertFrom-JsonElement -Element $document.RootElement
    } finally {
        $document.Dispose()
    }
}

function Copy-JsonObject {
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject) { return [pscustomobject]@{} }
    return ConvertFrom-ArmJson -Json ($InputObject | ConvertTo-Json -Depth 100 -Compress)
}

function Add-OrReplaceObjectProperty {
    param([object]$InputObject, [string]$Name, [AllowNull()][object]$Value)

    if ($null -ne $InputObject.PSObject.Properties[$Name]) { $InputObject.$Name = $Value }
    else { $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-ComparableSetting {
    param([object]$Settings, [bool]$ExcludeConsent)

    $copy = Copy-JsonObject -InputObject $Settings
    $excluded = @('LicenseType')
    if ($ExcludeConsent) { $excluded += 'ConsentToRecurringPAYG' }
    foreach ($name in $excluded) {
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

function Test-ExtensionUnchanged {
    param([object]$Before, [object]$After)

    if (-not (Test-JsonSemanticEqual -Left $Before.properties.settings -Right $After.properties.settings)) { return $false }
    if (-not (Test-JsonSemanticEqual -Left $Before.tags -Right $After.tags)) { return $false }
    if ([string]$Before.location -ne [string]$After.location) { return $false }
    foreach ($name in @('publisher', 'type', 'typeHandlerVersion', 'autoUpgradeMinorVersion', 'enableAutomaticUpgrade', 'forceUpdateTag')) {
        if (-not (Test-JsonSemanticEqual -Left $Before.properties.$name -Right $After.properties.$name)) { return $false }
    }
    return $true
}

function ConvertTo-ExtensionRequestBody {
    param([pscustomobject]$Preflight, [string]$ConsentTimestamp)

    $extension = $Preflight.Extension
    $settings = Copy-JsonObject -InputObject $extension.properties.settings
    Add-OrReplaceObjectProperty -InputObject $settings -Name 'LicenseType' -Value $Preflight.Item.LicenseType
    if ($Preflight.WriteConsent) {
        Add-OrReplaceObjectProperty -InputObject $settings -Name 'ConsentToRecurringPAYG' -Value ([pscustomobject][ordered]@{
            Consented = $true
            ConsentTimestamp = $ConsentTimestamp
        })
    }
    $before = Get-ComparableSetting -Settings $extension.properties.settings -ExcludeConsent $Preflight.WriteConsent
    $after = Get-ComparableSetting -Settings $settings -ExcludeConsent $Preflight.WriteConsent
    if (-not (Test-JsonSemanticEqual -Left $before -Right $after)) {
        throw 'Refusing to send a request that would change any setting other than LicenseType and the requested consent.'
    }

    $properties = [ordered]@{
        publisher = [string]$extension.properties.publisher
        type = [string]$extension.properties.type
    }
    foreach ($name in @('typeHandlerVersion', 'autoUpgradeMinorVersion', 'enableAutomaticUpgrade', 'forceUpdateTag')) {
        if ($null -ne $extension.properties.PSObject.Properties[$name]) { $properties[$name] = $extension.properties.$name }
    }
    $properties.settings = $settings
    $body = [ordered]@{ location = [string]$extension.location }
    # PUT replaces the tracked resource, so existing extension tags must be sent back.
    if ($null -ne $extension.PSObject.Properties['tags'] -and $null -ne $extension.tags) { $body.tags = $extension.tags }
    $body.properties = $properties
    return ($body | ConvertTo-Json -Depth 100 -Compress)
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
            Start-Sleep -Seconds (Get-RetryDelaySecond -Headers $response.Headers -DefaultSeconds $fallbackSeconds)
        }
    }
    throw "Asynchronous operation did not complete after $($script:Configuration.PollAttempts) polls."
}

function Wait-VerifiedExtension {
    param([pscustomobject]$Preflight, [hashtable]$Headers)

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
            if ((ConvertTo-CanonicalLicenseType -Value $extension.properties.settings.LicenseType) -cne $Preflight.Item.LicenseType) { $problems.Add('LicenseType') }
            if ($Preflight.WriteConsent -and (ConvertTo-StrictBoolean -Value $extension.properties.settings.ConsentToRecurringPAYG.Consented -AllowEmpty) -ne $true) { $problems.Add('ConsentToRecurringPAYG') }
            $before = Get-ComparableSetting -Settings $Preflight.Extension.properties.settings -ExcludeConsent $Preflight.WriteConsent
            $after = Get-ComparableSetting -Settings $extension.properties.settings -ExcludeConsent $Preflight.WriteConsent
            if (-not (Test-JsonSemanticEqual -Left $before -Right $after)) { $problems.Add('unrelated settings') }
            if ($problems.Count -eq 0) { return $extension }
            $lastProblems = $problems.ToArray()
        }
        if ($attempt -lt $script:Configuration.PollAttempts) {
            $fallbackSeconds = [int][math]::Min($script:Configuration.PollIntervalSeconds * [math]::Pow(2, $attempt - 1), 60)
            Start-Sleep -Seconds (Get-RetryDelaySecond -Headers $response.Headers -DefaultSeconds $fallbackSeconds)
        }
    }
    if ($lastProblems.Count -gt 0) {
        throw "Final extension verification timed out after $($script:Configuration.PollAttempts) polls; settings did not converge for: $($lastProblems -join ', ')."
    }
    throw "Extension provisioning did not reach Succeeded after $($script:Configuration.PollAttempts) polls."
}

function Format-Result {
    param([pscustomobject]$Preflight, [string]$Status, [string]$Message, [bool]$Verified)

    $changed = $Status -eq 'Succeeded'
    return [pscustomobject][ordered]@{
        RowNumber = $Preflight.Item.RowNumber
        SubscriptionId = $Preflight.Item.SubscriptionId
        ResourceGroupName = $Preflight.Item.ServerResourceGroupName
        MachineName = $Preflight.Item.ARCServerName
        MachineResourceId = $Preflight.Item.MachineResourceId
        PreviousLicenseType = $Preflight.CurrentLicenseType
        RequestedLicenseType = $Preflight.Item.LicenseType
        EffectiveLicenseType = if ($Status -in @('Succeeded', 'AlreadyCompliant')) { $Preflight.Item.LicenseType } else { $Preflight.CurrentLicenseType }
        ConsentToRecurringPAYGRecorded = $changed -and [bool]$Preflight.WriteConsent
        EsuEnabled = $Preflight.EsuEnabled
        HostType = $Preflight.HostType
        DetectedCores = $Preflight.DetectedCores
        InstanceNames = @($Preflight.Instances | ForEach-Object Name) -join ', '
        Editions = @($Preflight.Instances | ForEach-Object Edition | Select-Object -Unique) -join ', '
        OperationStatus = $Status
        VerificationSucceeded = $Verified
        Message = $Message
    }
}

$plan = ConvertTo-PlanItem -ParameterSetName $PSCmdlet.ParameterSetName `
    -DefaultSubscriptionId $subscriptionId -ResourceGroupName $serverResourceGroupName `
    -MachineName $ARCServerName -RequestedLicenseType $LicenseType `
    -SoftwareAssuranceAttested $AttestSoftwareAssurance.IsPresent `
    -PaygBillingAccepted $AcceptPaygBilling.IsPresent `
    -RecurringPaygConsented $ConsentToRecurringPAYG.IsPresent `
    -CoreBasedEnterpriseConfirmed $ConfirmCoreBasedEnterpriseLicense.IsPresent -Path $csvFilePath

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
        if (-not $preflight.AlreadyCompliant) {
            foreach ($impact in (Get-ImpactWarning -Preflight $preflight)) { Write-Warning "$($item.MachineResourceId): $impact" }
        }
    } catch {
        $placeholder = [pscustomobject]@{
            Item = $item; Instances = @(); CurrentLicenseType = $null; EsuEnabled = $null
            WriteConsent = $false; HostType = $null; DetectedCores = $null
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
    if ($preflight.AlreadyCompliant) {
        $results.Add((Format-Result -Preflight $preflight -Status 'AlreadyCompliant' -Message 'LicenseType already has the requested value; no PUT was sent.' -Verified $true))
        continue
    }
    if ($DryRun) {
        $results.Add((Format-Result -Preflight $preflight -Status 'Previewed' -Message 'Dry run completed after full read-only preflight; no PUT was sent.' -Verified $false))
        continue
    }

    $consentText = if ($preflight.WriteConsent) { ' and record ConsentToRecurringPAYG (irreversible without reinstalling the extension)' } else { '' }
    $action = "Set host-wide SQL Server LicenseType from empty to '$($item.LicenseType)'$consentText. Review the warnings above; this is a licensing attestation or billing decision."
    if (-not $PSCmdlet.ShouldProcess($item.MachineResourceId, $action)) {
        $status = if ($WhatIfPreference) { 'Previewed' } else { 'Declined' }
        $results.Add((Format-Result -Preflight $preflight -Status $status -Message 'No PUT was sent.' -Verified $false))
        continue
    }

    try {
        # Re-read immediately before the PUT: confirmation prompts and earlier hosts' polling can
        # take minutes, and the body must never be built from a stale snapshot that could
        # overwrite a LicenseType, ESU state, or other setting changed since preflight.
        $fresh = Get-PreflightRecord -Item $item -Headers $headers -ProviderCache $providerCache -InstanceCache $instanceCache
        if ($fresh.AlreadyCompliant) {
            $results.Add((Format-Result -Preflight $fresh -Status 'AlreadyCompliant' -Message 'LicenseType was set to the requested value by another process after preflight; no PUT was sent.' -Verified $true))
            continue
        }
        if (-not (Test-ExtensionUnchanged -Before $preflight.Extension -After $fresh.Extension) -or $fresh.WriteConsent -ne $preflight.WriteConsent) {
            throw 'The SQL extension changed after preflight, so the reviewed warnings may no longer be accurate. No PUT was sent; run the script again.'
        }
        $preflight = $fresh

        $consentTimestamp = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $body = ConvertTo-ExtensionRequestBody -Preflight $preflight -ConsentTimestamp $consentTimestamp
        $response = Invoke-ArmRequest -Uri (Get-ExtensionUri $item) -Method PUT -Headers $headers -Body $body
        if ($response.StatusCode -notin @(200, 201, 202)) { throw "Extension update failed (HTTP $($response.StatusCode))." }
        if ($response.StatusCode -eq 202) {
            $operationUri = Get-HeaderValue -Headers $response.Headers -Names @('Azure-AsyncOperation', 'Location')
            if ([string]::IsNullOrWhiteSpace($operationUri)) { throw 'Extension update returned 202 without an operation polling URL.' }
            Assert-TrustedArmUri -Uri $operationUri -Purpose 'operation polling'
            Wait-ArmOperation -OperationUri $operationUri -Headers $headers
        }
        Wait-VerifiedExtension -Preflight $preflight -Headers $headers | Out-Null
        $results.Add((Format-Result -Preflight $preflight -Status 'Succeeded' -Message 'LicenseType was set and verified; all other extension settings were preserved.' -Verified $true))
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
