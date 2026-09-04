<#
.SYNOPSIS
Installs the Azure Extension for SQL Server on an existing Windows Arc-enabled machine.

.DESCRIPTION
Installs WindowsAgent.SqlServer only when it is absent. Existing extensions are never
updated, repaired, or upgraded. The script performs local validation before authentication,
then completes read-only machine, provider, and extension preflight for every target before
the first PUT request.

The script supports service principal authentication or a valid Get-AzAccessToken token
object. It targets commercial Azure and does not install or modify the Connected Machine
agent. Installing this extension does not enable SQL Server Extended Security Updates.

.EXAMPLE
$token = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
./Scripts/sql/InstallSQLServerArcExtension.ps1 -subscriptionId '00000000-0000-0000-0000-000000000001' `
    -serverResourceGroupName 'rg-arc-servers' -ARCServerName 'sql-host-01' `
    -LicenseType Paid -ConfirmExternalPrerequisites -userToken $token -DryRun

.EXAMPLE
./Scripts/sql/InstallSQLServerArcExtension.ps1 -subscriptionId '00000000-0000-0000-0000-000000000001' `
    -csvFilePath 'C:\Temp\InstallSQLServerArcExtension.csv' `
    -tenantId '00000000-0000-0000-0000-000000000002' `
    -appID '00000000-0000-0000-0000-000000000003' `
    -clientSecret 'fictitious-client-secret' -WhatIf
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
    [switch]$ConfirmExternalPrerequisites,

    [Parameter(Mandatory, ParameterSetName = 'Csv')]
    [Alias('csv')]
    [string]$csvFilePath,

    [string]$tenantId,

    [string]$appID,

    [Alias('s', 'secret', 'sec')]
    [string]$clientSecret,

    [Alias('token')]
    [System.Object]$userToken,

    [Alias('Preview')]
    [switch]$DryRun
)

$script:Configuration = @{
    ArmEndpoint = 'https://management.azure.com'
    LoginEndpoint = 'https://login.microsoftonline.com'
    MachineApiVersion = '2026-07-15'
    ExtensionApiVersion = '2026-07-15'
    ProviderApiVersion = '2021-04-01'
    ExtensionName = 'WindowsAgent.SqlServer'
    ExtensionPublisher = 'Microsoft.AzureData'
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

    return -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value -match '^[a-zA-Z0-9_\-.]{1,54}$'
}

function ConvertTo-PlanItems {
    param(
        [string]$ParameterSetName,
        [string]$DefaultSubscriptionId,
        [string]$ResourceGroupName,
        [string]$MachineName,
        [string]$RequestedLicenseType,
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
            LicenseType = $RequestedLicenseType
            ConfirmExternalPrerequisites = $ExternalPrerequisitesConfirmed.ToString()
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

        $requiredColumns = @('SubscriptionId', 'ServerResourceGroupName', 'ARCServerName', 'LicenseType', 'ConfirmExternalPrerequisites')
        $actualColumns = @($sourceRows[0].PSObject.Properties.Name)
        $missingColumns = @($requiredColumns | Where-Object { $_ -notin $actualColumns })
        if ($missingColumns.Count -gt 0) {
            $errors.Add("CSV is missing required columns: $($missingColumns -join ', ').")
            return [pscustomobject]@{ Items = @(); Errors = $errors.ToArray() }
        }

        $unknownColumns = @($actualColumns | Where-Object { $_ -notin $requiredColumns })
        foreach ($column in $unknownColumns) {
            Write-Warning "Ignoring unsupported CSV column '$column'."
        }
    }

    $seenResourceIds = @{}
    for ($index = 0; $index -lt $sourceRows.Count; $index++) {
        $row = $sourceRows[$index]
        $rowNumber = $index + 2
        $effectiveSubscriptionId = if ([string]::IsNullOrWhiteSpace([string]$row.SubscriptionId)) {
            $DefaultSubscriptionId
        } else {
            ([string]$row.SubscriptionId).Trim()
        }
        $effectiveResourceGroup = ([string]$row.ServerResourceGroupName).Trim()
        $effectiveMachineName = ([string]$row.ARCServerName).Trim()
        $effectiveLicenseType = ([string]$row.LicenseType).Trim()
        $confirmation = ([string]$row.ConfirmExternalPrerequisites).Trim()
        $rowErrors = [System.Collections.Generic.List[string]]::new()

        if (-not (Test-SubscriptionId $effectiveSubscriptionId)) {
            $rowErrors.Add('SubscriptionId must be a valid GUID supplied by the row or command.')
        }
        if (-not (Test-ResourceGroupName $effectiveResourceGroup)) {
            $rowErrors.Add('ServerResourceGroupName is invalid.')
        }
        if (-not (Test-MachineName $effectiveMachineName)) {
            $rowErrors.Add('ARCServerName must be 1-54 supported characters.')
        }
        if ($effectiveLicenseType -notin @('Paid', 'PAYG', 'LicenseOnly')) {
            $rowErrors.Add('LicenseType must be Paid, PAYG, or LicenseOnly.')
        }
        if ($confirmation -ine 'TRUE') {
            $rowErrors.Add('ConfirmExternalPrerequisites must be TRUE.')
        }

        if ($rowErrors.Count -eq 0) {
            $resourceId = "/subscriptions/$effectiveSubscriptionId/resourceGroups/$effectiveResourceGroup/providers/Microsoft.HybridCompute/machines/$effectiveMachineName"
            $identityKey = $resourceId.ToLowerInvariant()
            if ($seenResourceIds.ContainsKey($identityKey)) {
                $rowErrors.Add("Duplicate machine target; first specified on row $($seenResourceIds[$identityKey]).")
            } else {
                $seenResourceIds[$identityKey] = $rowNumber
            }
        }

        if ($rowErrors.Count -gt 0) {
            $errors.Add("Row ${rowNumber}: $($rowErrors -join ' ')")
            continue
        }

        $items.Add([pscustomobject]@{
            RowNumber = $rowNumber
            SubscriptionId = $effectiveSubscriptionId
            ServerResourceGroupName = $effectiveResourceGroup
            ARCServerName = $effectiveMachineName
            LicenseType = $effectiveLicenseType
            MachineResourceId = $resourceId
        })
    }

    return [pscustomobject]@{ Items = $items.ToArray(); Errors = $errors.ToArray() }
}

function Get-BearerToken {
    param(
        [System.Object]$TokenObject,
        [string]$Tenant,
        [string]$ApplicationId,
        [string]$Secret
    )

    if ($null -ne $TokenObject) {
        if ($Tenant -or $ApplicationId -or $Secret) {
            throw 'Provide either userToken or the complete service principal credentials, not both.'
        }
        if ($null -eq $TokenObject.ExpiresOn -or $TokenObject.ExpiresOn -le (Get-Date)) {
            throw 'The provided user token is expired or has no valid expiration time.'
        }
        if ($null -eq $TokenObject.Token) {
            throw 'The provided user token object has no Token value.'
        }
        if ($TokenObject.Token -is [securestring]) {
            return ConvertFrom-SecureString -SecureString $TokenObject.Token -AsPlainText
        }
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
    if ([string]::IsNullOrWhiteSpace([string]$authResponse.access_token)) {
        throw 'Authentication response did not contain an access token.'
    }
    return [string]$authResponse.access_token
}

function Invoke-ArmRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT')][string]$Method,
        [Parameter(Mandatory)][hashtable]$Headers,
        [string]$Body
    )

    $requestParameters = @{
        Uri = $Uri
        Method = $Method
        Headers = $Headers
        ErrorAction = 'Stop'
        SkipHttpErrorCheck = $true
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $requestParameters.Body = $Body
        $requestParameters.ContentType = 'application/json'
    }

    $transientStatusCodes = @(408, 429, 500, 502, 503, 504)
    for ($attempt = 1; $attempt -le $script:Configuration.RequestAttempts; $attempt++) {
        $response = Invoke-WebRequest @requestParameters
        if ([int]$response.StatusCode -notin $transientStatusCodes -or $attempt -eq $script:Configuration.RequestAttempts) {
            break
        }

        $retryAfter = Get-RetryDelaySeconds -Headers $response.Headers -DefaultSeconds $script:Configuration.RequestRetryIntervalSeconds
        Start-Sleep -Seconds $retryAfter
    }

    $content = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$response.Content)) {
        try {
            $content = $response.Content | ConvertFrom-Json -Depth 100
        } catch {
            throw "ARM returned invalid JSON for $Method $Uri."
        }
    }

    if ($null -ne $content -and $null -ne $content.PSObject.Properties['nextLink'] -and
        -not [string]::IsNullOrWhiteSpace([string]$content.nextLink)) {
        Assert-TrustedArmUri -Uri ([string]$content.nextLink) -Purpose 'nextLink'
    }

    return [pscustomobject]@{
        StatusCode = [int]$response.StatusCode
        Headers = $response.Headers
        Content = $content
    }
}

function Get-HeaderValue {
    param(
        [System.Object]$Headers,
        [string[]]$Names
    )

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
    param(
        [System.Object]$Headers,
        [int]$DefaultSeconds
    )

    $retryAfter = Get-HeaderValue -Headers $Headers -Names @('Retry-After')
    $seconds = 0
    if ([int]::TryParse($retryAfter, [ref]$seconds) -and $seconds -ge 0) {
        return [math]::Min($seconds, 60)
    }

    $retryAfterMilliseconds = Get-HeaderValue -Headers $Headers -Names @('x-ms-retry-after-ms')
    $milliseconds = 0
    if ([int]::TryParse($retryAfterMilliseconds, [ref]$milliseconds) -and $milliseconds -ge 0) {
        return [math]::Min([int][math]::Ceiling($milliseconds / 1000), 60)
    }

    return $DefaultSeconds
}

function Assert-TrustedArmUri {
    param(
        [string]$Uri,
        [string]$Purpose
    )

    $parsedUri = $null
    $armUri = [uri]$script:Configuration.ArmEndpoint
    if (-not [uri]::TryCreate($Uri, [System.UriKind]::Absolute, [ref]$parsedUri) -or
        $parsedUri.Scheme -ine 'https' -or $parsedUri.Host -ine $armUri.Host -or
        -not [string]::IsNullOrWhiteSpace($parsedUri.UserInfo)) {
        throw "ARM returned an untrusted $Purpose URL."
    }
}

function Wait-PollInterval {
    param([System.Object]$Response)

    $seconds = Get-RetryDelaySeconds -Headers $Response.Headers -DefaultSeconds $script:Configuration.PollIntervalSeconds
    Start-Sleep -Seconds $seconds
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

function Test-ProviderRegistration {
    param(
        [string]$Subscription,
        [string]$Namespace,
        [hashtable]$Headers
    )

    $uri = "$($script:Configuration.ArmEndpoint)/subscriptions/$Subscription/providers/$Namespace`?api-version=$($script:Configuration.ProviderApiVersion)"
    $response = Invoke-ArmRequest -Uri $uri -Method GET -Headers $Headers
    if ($response.StatusCode -ne 200) {
        throw "Unable to read provider '$Namespace' registration (HTTP $($response.StatusCode))."
    }
    if ([string]$response.Content.registrationState -ine 'Registered') {
        throw "Provider '$Namespace' is not registered. Registration state: '$($response.Content.registrationState)'."
    }
    return $response.Content
}

function Test-MachinePreflight {
    param(
        [pscustomobject]$Item,
        [hashtable]$Headers,
        [hashtable]$ProviderCache
    )

    $machineResponse = Invoke-ArmRequest -Uri (Get-MachineUri $Item) -Method GET -Headers $Headers
    if ($machineResponse.StatusCode -ne 200) {
        throw "Arc machine GET failed (HTTP $($machineResponse.StatusCode)). The machine must already exist."
    }
    $machine = $machineResponse.Content
    if ([string]::IsNullOrWhiteSpace([string]$machine.location)) {
        throw 'Arc machine response has no location.'
    }
    if ([string]$machine.properties.status -ine 'Connected') {
        throw "Arc machine is not connected. Status: '$($machine.properties.status)'."
    }
    if ([string]$machine.properties.agentConfiguration.mode -ine 'Full') {
        throw "Arc machine agent mode must be Full. Mode: '$($machine.properties.agentConfiguration.mode)'."
    }
    $operatingSystem = if ($machine.properties.osName) { $machine.properties.osName } else { $machine.properties.osType }
    if ([string]$operatingSystem -notmatch 'Windows') {
        throw "Arc machine must report Windows. Operating system: '$operatingSystem'."
    }
    $cloudProvider = if ($machine.properties.detectedProperties.cloudProvider) {
        $machine.properties.detectedProperties.cloudProvider
    } else {
        $machine.properties.cloudMetadataProvider
    }
    if ([string]$cloudProvider -ieq 'Azure') {
        throw 'Native Azure virtual machines must use the SQL IaaS Agent extension, not this Arc workflow.'
    }

    if (-not $ProviderCache.ContainsKey($Item.SubscriptionId)) {
        $hybridCompute = Test-ProviderRegistration -Subscription $Item.SubscriptionId -Namespace 'Microsoft.HybridCompute' -Headers $Headers
        $azureArcData = Test-ProviderRegistration -Subscription $Item.SubscriptionId -Namespace 'Microsoft.AzureArcData' -Headers $Headers
        $ProviderCache[$Item.SubscriptionId] = [pscustomobject]@{
            HybridCompute = $hybridCompute
            AzureArcData = $azureArcData
        }
    }

    $arcDataProvider = $ProviderCache[$Item.SubscriptionId].AzureArcData
    $sqlResourceType = @($arcDataProvider.resourceTypes | Where-Object { $_.resourceType -ieq 'sqlServerInstances' }) | Select-Object -First 1
    if ($null -eq $sqlResourceType) {
        throw 'Microsoft.AzureArcData capability metadata does not include sqlServerInstances.'
    }
    if (@($sqlResourceType.locations).Count -eq 0) {
        throw 'Microsoft.AzureArcData/sqlServerInstances regional capability is indeterminate.'
    }
    $normalizedLocation = ([string]$machine.location -replace '\s', '').ToLowerInvariant()
    $supportedLocations = @($sqlResourceType.locations | ForEach-Object { ([string]$_ -replace '\s', '').ToLowerInvariant() })
    if ($normalizedLocation -notin $supportedLocations) {
        throw "Machine location '$($machine.location)' is not listed for Microsoft.AzureArcData/sqlServerInstances."
    }

    $extensionResponse = Invoke-ArmRequest -Uri (Get-ExtensionUri $Item) -Method GET -Headers $Headers
    if ($extensionResponse.StatusCode -eq 404) {
        return [pscustomobject]@{ Machine = $machine; ExistingExtension = $null }
    }
    if ($extensionResponse.StatusCode -ne 200) {
        throw "Extension GET failed (HTTP $($extensionResponse.StatusCode))."
    }

    $extension = $extensionResponse.Content
    $publisher = [string]$extension.properties.publisher
    $extensionType = [string]$extension.properties.type
    if ([string]::IsNullOrWhiteSpace($publisher) -or [string]::IsNullOrWhiteSpace($extensionType)) {
        throw 'Existing extension identity is indeterminate; publisher and type are required.'
    }
    if ($publisher -ine $script:Configuration.ExtensionPublisher -or $extensionType -ine $script:Configuration.ExtensionName) {
        throw "Existing extension identity conflicts with $($script:Configuration.ExtensionPublisher)/$($script:Configuration.ExtensionName)."
    }

    return [pscustomobject]@{ Machine = $machine; ExistingExtension = $extension }
}

function ConvertTo-ExtensionRequestBody {
    param(
        [string]$Location,
        [string]$RequestedLicenseType
    )

    $body = @{
        location = $Location
        properties = @{
            publisher = $script:Configuration.ExtensionPublisher
            type = $script:Configuration.ExtensionName
            enableAutomaticUpgrade = $true
            settings = @{
                SqlManagement = @{ IsEnabled = $true }
                LicenseType = $RequestedLicenseType
                ExcludedSqlInstances = @()
            }
        }
    }
    return $body | ConvertTo-Json -Depth 10
}

function Wait-ArmOperation {
    param(
        [string]$OperationUri,
        [hashtable]$Headers
    )

    for ($attempt = 1; $attempt -le $script:Configuration.PollAttempts; $attempt++) {
        $response = Invoke-ArmRequest -Uri $OperationUri -Method GET -Headers $Headers
        if ($response.StatusCode -notin @(200, 201, 202)) {
            throw "Asynchronous operation polling failed (HTTP $($response.StatusCode))."
        }
        $state = if ($response.Content.status) {
            [string]$response.Content.status
        } else {
            [string]$response.Content.properties.provisioningState
        }
        if ($state -ieq 'Succeeded') { return }
        if ($state -in @('Failed', 'Canceled', 'Cancelled')) {
            throw "Asynchronous operation finished with state '$state'."
        }
        if ($attempt -lt $script:Configuration.PollAttempts) {
            Wait-PollInterval -Response $response
        }
    }
    throw "Asynchronous operation did not complete after $($script:Configuration.PollAttempts) polls."
}

function Test-InstalledExtension {
    param(
        [pscustomobject]$Extension,
        [string]$ExpectedLicenseType
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    if ([string]$Extension.properties.publisher -ine $script:Configuration.ExtensionPublisher) { $problems.Add('publisher') }
    if ([string]$Extension.properties.type -ine $script:Configuration.ExtensionName) { $problems.Add('type') }
    if ([string]$Extension.properties.provisioningState -ine 'Succeeded') { $problems.Add('provisioningState') }
    if ($Extension.properties.enableAutomaticUpgrade -ne $true) { $problems.Add('enableAutomaticUpgrade') }
    if ($Extension.properties.settings.SqlManagement.IsEnabled -ne $true) { $problems.Add('SqlManagement.IsEnabled') }
    if ([string]$Extension.properties.settings.LicenseType -cne $ExpectedLicenseType) { $problems.Add('LicenseType') }
    if ($null -eq $Extension.properties.settings.PSObject.Properties['ExcludedSqlInstances'] -or
        @($Extension.properties.settings.ExcludedSqlInstances).Count -ne 0) {
        $problems.Add('ExcludedSqlInstances')
    }
    if ($Extension.properties.settings.enableExtendedSecurityUpdates -eq $true -or
        [string]$Extension.properties.settings.enableExtendedSecurityUpdates -ieq 'true') {
        $problems.Add('enableExtendedSecurityUpdates')
    }
    if ($problems.Count -gt 0) {
        throw "Final extension verification failed for: $($problems -join ', ')."
    }
}

function Wait-InstalledExtension {
    param(
        [string]$ExtensionUri,
        [hashtable]$Headers,
        [string]$ExpectedLicenseType
    )

    for ($attempt = 1; $attempt -le $script:Configuration.PollAttempts; $attempt++) {
        $response = Invoke-ArmRequest -Uri $ExtensionUri -Method GET -Headers $Headers
        if ($response.StatusCode -ne 200) {
            throw "Final extension GET failed (HTTP $($response.StatusCode))."
        }

        $state = [string]$response.Content.properties.provisioningState
        if ($state -ieq 'Succeeded') {
            Test-InstalledExtension -Extension $response.Content -ExpectedLicenseType $ExpectedLicenseType
            return $response.Content
        }
        if ($state -in @('Failed', 'Canceled', 'Cancelled')) {
            throw "Extension provisioning finished with state '$state'."
        }
        if ($attempt -lt $script:Configuration.PollAttempts) {
            Wait-PollInterval -Response $response
        }
    }

    throw "Extension provisioning did not reach a terminal state after $($script:Configuration.PollAttempts) polls."
}

function ConvertTo-Result {
    param(
        [pscustomobject]$Item,
        [string]$Status,
        [string]$Message,
        [string]$ProvisioningState
    )

    return [pscustomobject]@{
        RowNumber = $Item.RowNumber
        SubscriptionId = $Item.SubscriptionId
        ServerResourceGroupName = $Item.ServerResourceGroupName
        ARCServerName = $Item.ARCServerName
        LicenseType = $Item.LicenseType
        Status = $Status
        ProvisioningState = $ProvisioningState
        Message = $Message
    }
}

$plan = ConvertTo-PlanItems -ParameterSetName $PSCmdlet.ParameterSetName `
    -DefaultSubscriptionId $subscriptionId -ResourceGroupName $serverResourceGroupName `
    -MachineName $ARCServerName -RequestedLicenseType $LicenseType `
    -ExternalPrerequisitesConfirmed $ConfirmExternalPrerequisites.IsPresent -Path $csvFilePath

if ($plan.Errors.Count -gt 0) {
    foreach ($validationError in $plan.Errors) { Write-Error $validationError }
    Write-Host "Planned: $($plan.Items.Count); Succeeded: 0; Already installed: 0; Previewed: 0; Declined: 0; Failed: $($plan.Errors.Count); Not started: 0"
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
$preflightResults = [System.Collections.Generic.List[object]]::new()
$providerCache = @{}

foreach ($item in $plan.Items) {
    try {
        $preflight = Test-MachinePreflight -Item $item -Headers $headers -ProviderCache $providerCache
        $preflightRecords.Add([pscustomobject]@{ Item = $item; Preflight = $preflight })
    } catch {
        $preflightResults.Add((ConvertTo-Result -Item $item -Status 'Failed' -Message $_.Exception.Message -ProvisioningState $null))
    }
}

if ($preflightResults.Count -gt 0) {
    foreach ($record in $preflightRecords) {
        $preflightResults.Add((ConvertTo-Result -Item $record.Item -Status 'NotStarted' -Message 'No changes were started because at least one target failed preflight.' -ProvisioningState $null))
    }
    $orderedResults = @($preflightResults | Sort-Object RowNumber)
    $orderedResults | Write-Output
    Write-Host "Planned: $($plan.Items.Count); Succeeded: 0; Already installed: 0; Previewed: 0; Declined: 0; Failed: $(@($orderedResults | Where-Object Status -eq 'Failed').Count); Not started: $(@($orderedResults | Where-Object Status -eq 'NotStarted').Count)"
    exit 1
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($record in $preflightRecords) {
    $item = $record.Item
    $preflight = $record.Preflight
    if ($null -ne $preflight.ExistingExtension) {
        $results.Add((ConvertTo-Result -Item $item -Status 'AlreadyInstalled' `
            -Message 'The expected extension already exists and was left untouched.' `
            -ProvisioningState ([string]$preflight.ExistingExtension.properties.provisioningState)))
        continue
    }

    if ($DryRun) {
        $results.Add((ConvertTo-Result -Item $item -Status 'Previewed' `
            -Message 'Dry run completed after read-only preflight; no PUT was sent.' -ProvisioningState $null))
        continue
    }

    $action = "Install $($script:Configuration.ExtensionPublisher)/$($script:Configuration.ExtensionName) with LicenseType '$($item.LicenseType)', SQL management enabled, automatic upgrades enabled, and local extension deployment impact; ESU will not be enabled"
    if (-not $PSCmdlet.ShouldProcess($item.MachineResourceId, $action)) {
        $status = if ($WhatIfPreference) { 'Previewed' } else { 'Declined' }
        $message = if ($WhatIfPreference) { 'WhatIf preview completed; no PUT was sent.' } else { 'Confirmation was declined; no PUT was sent.' }
        $results.Add((ConvertTo-Result -Item $item -Status $status -Message $message -ProvisioningState $null))
        continue
    }

    try {
        $extensionUri = Get-ExtensionUri $item
        $body = ConvertTo-ExtensionRequestBody -Location ([string]$preflight.Machine.location) -RequestedLicenseType $item.LicenseType
        $putResponse = Invoke-ArmRequest -Uri $extensionUri -Method PUT -Headers $headers -Body $body
        if ($putResponse.StatusCode -notin @(200, 201, 202)) {
            throw "Extension installation failed (HTTP $($putResponse.StatusCode))."
        }
        if ($putResponse.StatusCode -eq 202) {
            $operationUri = Get-HeaderValue -Headers $putResponse.Headers -Names @('Azure-AsyncOperation', 'Location')
            if ([string]::IsNullOrWhiteSpace($operationUri)) {
                throw 'Extension installation returned 202 without an operation polling URL.'
            }
            Assert-TrustedArmUri -Uri $operationUri -Purpose 'operation polling'
            Wait-ArmOperation -OperationUri $operationUri -Headers $headers
        }

        Wait-InstalledExtension -ExtensionUri $extensionUri -Headers $headers -ExpectedLicenseType $item.LicenseType | Out-Null
        $results.Add((ConvertTo-Result -Item $item -Status 'Succeeded' `
            -Message 'Extension installed and verified. SQL discovery can take time; ESU was not enabled.' `
            -ProvisioningState 'Succeeded'))
    } catch {
        $results.Add((ConvertTo-Result -Item $item -Status 'Failed' -Message $_.Exception.Message -ProvisioningState $null))
    }
}

$orderedResults = @($results | Sort-Object RowNumber)
$orderedResults | Write-Output
$succeeded = @($orderedResults | Where-Object Status -eq 'Succeeded').Count
$alreadyInstalled = @($orderedResults | Where-Object Status -eq 'AlreadyInstalled').Count
$previewed = @($orderedResults | Where-Object Status -eq 'Previewed').Count
$declined = @($orderedResults | Where-Object Status -eq 'Declined').Count
$failed = @($orderedResults | Where-Object Status -eq 'Failed').Count
$notStarted = @($orderedResults | Where-Object Status -eq 'NotStarted').Count
Write-Host "Planned: $($plan.Items.Count); Succeeded: $succeeded; Already installed: $alreadyInstalled; Previewed: $previewed; Declined: $declined; Failed: $failed; Not started: $notStarted"

if ($failed -gt 0 -or $declined -gt 0 -or $notStarted -gt 0) { exit 1 }
exit 0