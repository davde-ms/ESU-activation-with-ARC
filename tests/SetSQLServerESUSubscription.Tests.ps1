$scriptPath = Join-Path $PSScriptRoot '..\Scripts\sql\SetSQLServerESUSubscription.ps1'
$subscriptionId = '00000000-0000-0000-0000-000000000001'
$overrideSubscriptionId = '00000000-0000-0000-0000-000000000004'
$tenantId = '00000000-0000-0000-0000-000000000002'
$appId = '00000000-0000-0000-0000-000000000003'

function Invoke-SetScenario {
    param(
        [ValidateSet('Normal', 'LegacyString', 'AlreadyEnabled', 'AlreadyDisabled', 'LicenseOnly', 'Developer', 'UnsupportedVersion', 'UnsupportedEdition', 'Stale', 'Mixed', 'Physical', 'Async', 'VerificationConverges', 'VerificationMismatch', 'UnrelatedMismatch', 'RuntimeFailure', 'TransientPut', 'TransientPutFallback', 'UnsafeAsync', 'EvidenceUnavailable', 'WrongIdentity', 'LowercaseLicense')]
        [string]$Scenario = 'Normal',
        [string]$AdditionalArguments,
        [string]$CsvContent,
        [switch]$ServicePrincipal
    )

    $recordPath = Join-Path ([System.IO.Path]::GetTempPath()) "sql-esu-record-$PID-$([guid]::NewGuid().ToString('N')).jsonl"
    $csvPath = Join-Path ([System.IO.Path]::GetTempPath()) "sql-esu-input-$PID-$([guid]::NewGuid().ToString('N')).csv"
    if (-not [string]::IsNullOrWhiteSpace($CsvContent)) { Set-Content -LiteralPath $csvPath -Value $CsvContent }

    $escapedScriptPath = $scriptPath.Replace("'", "''")
    $escapedRecordPath = $recordPath.Replace("'", "''")
    $escapedCsvPath = $csvPath.Replace("'", "''")
    $authenticationArguments = if ($ServicePrincipal) {
        "-tenantId '$tenantId' -appID '$appId' -clientSecret 'fictitious-client-secret'"
    } else {
        '-userToken $token'
    }
    $targetArguments = if ([string]::IsNullOrWhiteSpace($CsvContent)) {
        "-subscriptionId '$subscriptionId' -serverResourceGroupName 'server-rg' -ARCServerName 'server-01'"
    } else {
        "-subscriptionId '$subscriptionId' -csvFilePath '$escapedCsvPath'"
    }
    $effectiveArguments = [string]$AdditionalArguments
    if ([string]::IsNullOrWhiteSpace($CsvContent) -and $effectiveArguments -notmatch '(?i)(^|\s)-Action(?:\s|:)') {
        $effectiveArguments += ' -Action Enable -Environment Production -AcceptBackBilling -ConfirmExternalPrerequisites'
    }

    $command = @"
`$global:mockScenario = '$Scenario'
`$global:requestCounts = @{}
`$global:updatedBodies = @{}
`$global:finalReadCounts = @{}

function global:New-MockWebResponse {
    param([int]`$StatusCode, [object]`$Content, [hashtable]`$Headers = @{})
    `$serialized = if (`$null -eq `$Content) { '' } elseif (`$Content -is [string]) { `$Content } else { `$Content | ConvertTo-Json -Depth 100 -Compress }
    return [pscustomobject]@{ StatusCode = `$StatusCode; Content = `$serialized; Headers = `$Headers }
}

function global:New-MockSettings {
    param([object]`$EsuEnabled = `$false, [string]`$LicenseType = 'Paid')
    return [ordered]@{
        SqlManagement = [ordered]@{ IsEnabled = `$true; Nested = [ordered]@{ FutureFlag = 'preserve-me' } }
        LicenseType = `$LicenseType
        ExcludedSqlInstances = @('ARCHIVE', 'LEGACY')
        enableExtendedSecurityUpdates = `$EsuEnabled
        esuLastUpdatedTimestamp = '2026-08-01T00:00:00.000Z'
        AzureDefender = [ordered]@{ IsEnabled = `$true; Rules = @([ordered]@{ Name = 'A'; Value = 1 }, [ordered]@{ Name = 'B'; Value = 2 }) }
        UseEsuPhysicalCoreLicense = [ordered]@{ IsApplied = `$false; Unknown = [ordered]@{ Keep = 'yes' } }
    }
}

function global:New-MockExtension {
    param([string]`$MachineName = 'server-01', [string]`$EffectiveSubscription = '$subscriptionId', [switch]`$Final)
    `$esu = if (`$global:mockScenario -in @('AlreadyEnabled', 'EvidenceUnavailable')) { `$true } elseif (`$global:mockScenario -eq 'LegacyString') { 'FALSE' } else { `$false }
    `$license = if (`$global:mockScenario -eq 'LicenseOnly') { 'LicenseOnly' } elseif (`$global:mockScenario -eq 'LowercaseLicense') { 'payg' } else { 'Paid' }
    `$settings = New-MockSettings -EsuEnabled `$esu -LicenseType `$license
    if (`$Final -and `$global:updatedBodies.ContainsKey(`$MachineName)) {
        `$settings = `$global:updatedBodies[`$MachineName].properties.settings | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json -Depth 100
        if (-not `$global:finalReadCounts.ContainsKey(`$MachineName)) { `$global:finalReadCounts[`$MachineName] = 0 }
        `$global:finalReadCounts[`$MachineName]++
        if (`$global:mockScenario -eq 'VerificationConverges' -and `$global:finalReadCounts[`$MachineName] -eq 1) { `$settings.enableExtendedSecurityUpdates = `$false }
        if (`$global:mockScenario -eq 'VerificationMismatch') { `$settings.enableExtendedSecurityUpdates = `$false }
        if (`$global:mockScenario -eq 'UnrelatedMismatch') { `$settings.AzureDefender.Rules[0].Value = 99 }
    }
    return [ordered]@{
        id = "/subscriptions/`$EffectiveSubscription/resourceGroups/server-rg/providers/Microsoft.HybridCompute/machines/`$MachineName/extensions/WindowsAgent.SqlServer"
        name = 'WindowsAgent.SqlServer'
        type = 'Microsoft.HybridCompute/machines/extensions'
        location = 'westus2'
        systemData = @{ createdBy = 'response-only' }
        properties = [ordered]@{
            publisher = if (`$global:mockScenario -eq 'WrongIdentity') { 'Contoso.Unsupported' } else { 'Microsoft.AzureData' }
            type = 'WindowsAgent.SqlServer'
            typeHandlerVersion = if (`$global:mockScenario -eq 'EvidenceUnavailable' -and -not `$global:updatedBodies.ContainsKey(`$MachineName)) { `$null } else { '1.1.3518.465' }
            autoUpgradeMinorVersion = `$true
            enableAutomaticUpgrade = `$true
            forceUpdateTag = 'existing-tag'
            provisioningState = if (`$global:mockScenario -eq 'EvidenceUnavailable' -and -not `$global:updatedBodies.ContainsKey(`$MachineName)) { `$null } else { 'Succeeded' }
            instanceView = @{ status = @{ code = 'response-only' } }
            protectedSettings = @{ secret = 'must-not-copy' }
            settings = `$settings
        }
    }
}

function global:New-MockInstance {
    param([string]`$MachineName, [string]`$Name = 'MSSQLSERVER', [string]`$Version = '13.0.7000.0', [string]`$Edition = 'Enterprise Edition', [string]`$HostType = 'VirtualMachine', [int]`$Cores = 8)
    `$timestamp = if (`$global:mockScenario -eq 'Stale') { '2026-08-01T00:00:00Z' } else { [datetime]::UtcNow.ToString('o') }
    return [ordered]@{
        id = "/subscriptions/$subscriptionId/resourceGroups/server-rg/providers/Microsoft.AzureArcData/sqlServerInstances/`$Name"
        name = `$Name
        properties = [ordered]@{
            containerResourceId = "/subscriptions/$subscriptionId/resourceGroups/server-rg/providers/Microsoft.HybridCompute/machines/`$MachineName"
            version = `$Version
            edition = `$Edition
            serviceType = if (`$Name -eq 'MSSQLSERVER') { 'DatabaseEngine' } else { 'AnalysisServices' }
            hostType = `$HostType
            vCore = `$Cores
            lastInventoryUploadTime = `$timestamp
            lastUsageUploadTime = `$timestamp
            isPassive = `$false
        }
    }
}

function global:Start-Sleep {
    param([int]`$Seconds)
    [pscustomobject]@{ Uri = ''; Method = 'SLEEP'; Body = [string]`$Seconds; IsAuthentication = `$false } | ConvertTo-Json -Compress | Add-Content -LiteralPath '$escapedRecordPath'
}

function global:Invoke-WebRequest {
    param(`$Uri, `$Method, `$Headers, `$Body, `$ContentType, `$ErrorAction, `$SkipHttpErrorCheck)
    [pscustomobject]@{ Uri = [string]`$Uri; Method = [string]`$Method; Body = [string]`$Body; IsAuthentication = ([string]`$Uri -like 'https://login.microsoftonline.com/*') } | ConvertTo-Json -Compress | Add-Content -LiteralPath '$escapedRecordPath'
    `$key = "`$Method `$Uri"
    if (-not `$global:requestCounts.ContainsKey(`$key)) { `$global:requestCounts[`$key] = 0 }
    `$global:requestCounts[`$key]++

    if ([string]`$Uri -like 'https://login.microsoftonline.com/*') { return New-MockWebResponse 200 @{ access_token = 'fictitious-access-token' } }
    if ([string]`$Uri -eq 'https://management.azure.com/operations/esu-01') {
        if (`$global:requestCounts[`$key] -eq 1) { return New-MockWebResponse 202 @{ status = 'InProgress' } @{ 'Retry-After' = '0' } }
        return New-MockWebResponse 200 @{ status = 'Succeeded' }
    }
    if ([string]`$Uri -match '/providers/Microsoft\.HybridCompute\?api-version=2021-04-01$') {
        if (`$global:mockScenario -eq 'EvidenceUnavailable') { return New-MockWebResponse 503 @{ error = @{ code = 'Unavailable' } } }
        return New-MockWebResponse 200 @{ registrationState = 'Registered'; resourceTypes = @() }
    }
    if ([string]`$Uri -match '/providers/Microsoft\.AzureArcData\?api-version=2021-04-01$') {
        if (`$global:mockScenario -eq 'EvidenceUnavailable') { return New-MockWebResponse 503 @{ error = @{ code = 'Unavailable' } } }
        return New-MockWebResponse 200 @{ registrationState = 'Registered'; resourceTypes = @(@{ resourceType = 'sqlServerInstances'; locations = @('West US 2') }) }
    }
    if ([string]`$Uri -match '/providers/Microsoft\.AzureArcData/sqlServerInstances\?api-version=2026-01-01$') {
        if (`$global:mockScenario -eq 'EvidenceUnavailable') { return New-MockWebResponse 503 @{ error = @{ code = 'Unavailable' } } }
        `$machines = @('server-01', 'server-02')
        `$instances = @()
        foreach (`$machine in `$machines) {
            `$version = if (`$global:mockScenario -eq 'UnsupportedVersion') { '11.0.7507.2' } else { '13.0.7000.0' }
            `$edition = if (`$global:mockScenario -eq 'Developer') { 'Developer Edition' } elseif (`$global:mockScenario -eq 'UnsupportedEdition') { 'Express Edition' } else { 'Enterprise Edition' }
            `$hostType = if (`$global:mockScenario -eq 'Physical') { 'PhysicalServer' } else { 'VirtualMachine' }
            `$cores = if (`$global:mockScenario -eq 'Physical') { 32 } else { 2 }
            `$instances += New-MockInstance -MachineName `$machine -Version `$version -Edition `$edition -HostType `$hostType -Cores `$cores
            if (`$global:mockScenario -eq 'Mixed') { `$instances += New-MockInstance -MachineName `$machine -Name 'SQL2014' -Version '12.0.6449.1' -Edition 'Standard Edition' -HostType `$hostType -Cores `$cores }
        }
        return New-MockWebResponse 200 @{ value = `$instances }
    }
    if ([string]`$Uri -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.HybridCompute/machines/([^/?]+)/extensions/WindowsAgent\.SqlServer\?api-version=2026-07-15$') {
        `$effectiveSubscription = `$Matches[1]
        `$machine = `$Matches[3]
        if ([string]`$Method -eq 'PUT') {
            if (`$global:mockScenario -eq 'RuntimeFailure' -and `$machine -eq 'server-01') { return New-MockWebResponse 500 @{ error = @{ code = 'MockFailure' } } }
            if (`$global:mockScenario -eq 'TransientPut' -and `$global:requestCounts[`$key] -eq 1) { return New-MockWebResponse 503 @{ error = @{ code = 'Unavailable' } } @{ 'Retry-After' = '0' } }
            if (`$global:mockScenario -eq 'TransientPutFallback' -and `$global:requestCounts[`$key] -lt 4) { return New-MockWebResponse 503 @{ error = @{ code = 'Unavailable' } } }
            `$global:updatedBodies[`$machine] = `$Body | ConvertFrom-Json -Depth 100
            if (`$global:mockScenario -eq 'UnsafeAsync') { return New-MockWebResponse 202 `$null @{ Location = 'https://example.invalid/operations/esu-01' } }
            if (`$global:mockScenario -eq 'Async') { return New-MockWebResponse 202 `$null @{ Location = 'https://management.azure.com/operations/esu-01' } }
            return New-MockWebResponse 200 (New-MockExtension -MachineName `$machine -EffectiveSubscription `$effectiveSubscription)
        }
        return New-MockWebResponse 200 (New-MockExtension -MachineName `$machine -EffectiveSubscription `$effectiveSubscription -Final)
    }
    if ([string]`$Uri -match '/machines/([^/?]+)\?api-version=2026-07-15$') {
        `$machine = `$Matches[1]
        if (`$global:mockScenario -eq 'EvidenceUnavailable') { return New-MockWebResponse 503 @{ error = @{ code = 'Unavailable' } } }
        return New-MockWebResponse 200 @{
            id = "/subscriptions/$subscriptionId/resourceGroups/server-rg/providers/Microsoft.HybridCompute/machines/`$machine"
            location = 'westus2'
            properties = @{ status = 'Connected'; osName = 'Windows Server 2022'; agentConfiguration = @{ mode = 'Full' }; detectedProperties = @{ cloudProvider = 'VMware' } }
        }
    }
    return New-MockWebResponse 404 @{ error = @{ code = 'UnexpectedMockUri'; message = [string]`$Uri } }
}

`$token = [pscustomobject]@{ ExpiresOn = (Get-Date).AddMinutes(30); Token = ConvertTo-SecureString 'fictitious-user-token' -AsPlainText -Force }
& '$escapedScriptPath' $targetArguments $authenticationArguments $effectiveArguments -Confirm:`$false
exit `$LASTEXITCODE
"@

    try {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
        $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded"
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $completed = $process.WaitForExit(20000)
        if (-not $completed) { $process.Kill($true); $process.WaitForExit() }
        $output = $standardOutputTask.GetAwaiter().GetResult() + $standardErrorTask.GetAwaiter().GetResult()
        $exitCode = if ($completed) { $process.ExitCode } else { 124 }
        if (-not $completed) { $output += "`nScenario process exceeded 20 seconds." }
        $process.Dispose()
        $calls = if (Test-Path -LiteralPath $recordPath) { @(Get-Content -LiteralPath $recordPath | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; Calls = $calls }
    } finally {
        Remove-Item -LiteralPath $recordPath, $csvPath -ErrorAction SilentlyContinue
    }
}

Describe 'SetSQLServerESUSubscription command and local validation' {
    It 'exposes mutually exclusive single and CSV parameter sets with confirmation controls' {
        $command = Get-Command $scriptPath
        (@($command.ParameterSets | Where-Object Name -eq 'Single').Count -eq 1) | Should Be $true
        (@($command.ParameterSets | Where-Object Name -eq 'Csv').Count -eq 1) | Should Be $true
        (@($command.Parameters.Keys) -contains 'WhatIf') | Should Be $true
        (@($command.Parameters.Keys) -contains 'Confirm') | Should Be $true
        (@($command.Parameters.Keys) -contains 'DryRun') | Should Be $true
        (@($command.Parameters.Keys) -contains 'DetectedCores') | Should Be $false
    }

    It 'rejects missing enable acknowledgements before authentication' {
        $result = Invoke-SetScenario -AdditionalArguments '-Action Enable -Environment Production'
        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'AcceptBackBilling.*ConfirmExternalPrerequisites'
        $result.Calls.Count | Should Be 0
    }

    It 'requires disable rows to leave every enable-only field empty' {
        $result = Invoke-SetScenario -AdditionalArguments '-Action Disable -Environment Production'
        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'Disable requires.*enable-only'
        $result.Calls.Count | Should Be 0
    }

    It 'aggregates invalid CSV rows and uses row subscription overrides before authentication' {
        $csv = @"
SubscriptionId,ServerResourceGroupName,ARCServerName,Action,LicenseType,Environment,AcceptBackBilling,AcceptLicenseTypeChange,ConfirmNonProductionCoverage,ConfirmExternalPrerequisites
bad-guid,server-rg,server-01,Enable,LicenseOnly,Unknown,FALSE,FALSE,FALSE,FALSE
$overrideSubscriptionId,server-rg,server-02,Disable,,Production,,,,
"@
        $result = Invoke-SetScenario -CsvContent $csv
        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'Row 2:.*SubscriptionId.*LicenseType.*Environment.*AcceptBackBilling.*ConfirmExternalPrerequisites'
        $result.Output | Should Match 'Row 3:.*Disable requires'
        $result.Calls.Count | Should Be 0
    }

    It 'rejects unknown headers resembling controls but warns for unrelated headers' {
        $unsafeCsv = @"
SubscriptionId,ServerResourceGroupName,ARCServerName,Action,LicenseType,Environment,AcceptBackBilling,AcceptLicenseTypeChange,ConfirmNonProductionCoverage,ConfirmExternalPrerequisites,AcceptBackBiling
$subscriptionId,server-rg,server-01,Enable,,Production,TRUE,FALSE,FALSE,TRUE,TRUE
"@
        $safeCsv = @"
SubscriptionId,ServerResourceGroupName,ARCServerName,Action,LicenseType,Environment,AcceptBackBilling,AcceptLicenseTypeChange,ConfirmNonProductionCoverage,ConfirmExternalPrerequisites,ChangeTicket
$subscriptionId,server-rg,server-01,Enable,,Production,TRUE,FALSE,FALSE,TRUE,CHG001
"@
        $unsafe = Invoke-SetScenario -CsvContent $unsafeCsv
        $safe = Invoke-SetScenario -CsvContent $safeCsv -AdditionalArguments '-DryRun'
        $unsafe.ExitCode | Should Be 1
        $unsafe.Output | Should Match 'resemble billing acknowledgement or control fields.*AcceptBackBiling'
        $unsafe.Calls.Count | Should Be 0
        $safe.ExitCode | Should Be 0
        $safe.Output | Should Match "Ignoring unrelated CSV column 'ChangeTicket'"
    }
}

Describe 'SetSQLServerESUSubscription exact mutation behavior' {
    It 'writes Boolean true and preserves unknown nested settings while omitting response-only and protected fields' {
        $result = Invoke-SetScenario
        $result.ExitCode | Should Be 0
        $put = $result.Calls | Where-Object Method -eq 'PUT' | Select-Object -First 1
        $body = $put.Body | ConvertFrom-Json -Depth 100
        $body.properties.settings.enableExtendedSecurityUpdates | Should Be $true
        $put.Body | Should Match '"esuLastUpdatedTimestamp":"20\d\d-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z"'
        $body.properties.settings.ExcludedSqlInstances -join ',' | Should Be 'ARCHIVE,LEGACY'
        $body.properties.settings.SqlManagement.Nested.FutureFlag | Should Be 'preserve-me'
        $body.properties.settings.AzureDefender.Rules[1].Name | Should Be 'B'
        $body.properties.settings.UseEsuPhysicalCoreLicense.Unknown.Keep | Should Be 'yes'
        $body.properties.forceUpdateTag | Should Be 'existing-tag'
        $put.Body | Should Not Match 'systemData|instanceView|provisioningState|protectedSettings|response-only|must-not-copy'
    }

    It 'accepts legacy string state input but writes a JSON Boolean' {
        $result = Invoke-SetScenario -Scenario LegacyString
        $body = (($result.Calls | Where-Object Method -eq 'PUT' | Select-Object -First 1).Body | ConvertFrom-Json)
        $result.ExitCode | Should Be 0
        $body.properties.settings.enableExtendedSecurityUpdates -is [bool] | Should Be $true
    }

    It 'disables without changing LicenseType and writes Boolean false' {
        $result = Invoke-SetScenario -Scenario AlreadyEnabled -AdditionalArguments '-Action Disable'
        $body = (($result.Calls | Where-Object Method -eq 'PUT' | Select-Object -First 1).Body | ConvertFrom-Json)
        $result.ExitCode | Should Be 0
        $body.properties.settings.enableExtendedSecurityUpdates | Should Be $false
        $body.properties.settings.LicenseType | Should Be 'Paid'
    }

    It 'returns AlreadyCompliant without PUT or timestamp change' {
        $result = Invoke-SetScenario -Scenario AlreadyEnabled
        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'AlreadyCompliant|Already compliant'
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 0
    }

    It 'changes LicenseType only after the required acknowledgement' {
        $rejected = Invoke-SetScenario -AdditionalArguments '-LicenseType PAYG'
        $accepted = Invoke-SetScenario -AdditionalArguments '-LicenseType PAYG -AcceptLicenseTypeChange'
        $rejected.ExitCode | Should Be 1
        $rejected.Output | Should Match 'AcceptLicenseTypeChange must be TRUE'
        @($rejected.Calls | Where-Object Method -eq 'PUT').Count | Should Be 0
        $accepted.ExitCode | Should Be 0
        ((($accepted.Calls | Where-Object Method -eq 'PUT' | Select-Object -First 1).Body | ConvertFrom-Json).properties.settings.LicenseType) | Should Be 'PAYG'
    }

    It 'normalizes case-insensitive LicenseType values before comparison and PUT' {
        $result = Invoke-SetScenario -Scenario LowercaseLicense -AdditionalArguments '-LicenseType payg'
        $body = (($result.Calls | Where-Object Method -eq 'PUT' | Select-Object -First 1).Body | ConvertFrom-Json)
        $result.ExitCode | Should Be 0
        $body.properties.settings.LicenseType | Should Be 'PAYG'
        $result.Output | Should Not Match 'AcceptLicenseTypeChange must be TRUE'
    }

    It 'allows cancellation with unavailable eligibility and extension health evidence' {
        $result = Invoke-SetScenario -Scenario EvidenceUnavailable -AdditionalArguments '-Action Disable'
        $body = (($result.Calls | Where-Object Method -eq 'PUT' | Select-Object -First 1).Body | ConvertFrom-Json)
        $result.ExitCode | Should Be 0
        $body.properties.settings.enableExtendedSecurityUpdates | Should Be $false
        $body.properties.settings.SqlManagement.Nested.FutureFlag | Should Be 'preserve-me'
        $result.Output | Should Match 'degraded extension health evidence'
        $result.Output | Should Match 'unavailable or unsupported extension version evidence'
        @($result.Calls | Where-Object { $_.Uri -match '/providers/Microsoft\.(AzureArcData|HybridCompute)\?' -or $_.Uri -match '/sqlServerInstances\?' -or ($_.Uri -match '/machines/server-01\?' -and $_.Uri -notmatch '/extensions/') }).Count | Should Be 0
    }

    It 'rejects cancellation when the returned extension identity is wrong' {
        $result = Invoke-SetScenario -Scenario WrongIdentity -AdditionalArguments '-Action Disable'
        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'does not match the expected'
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 0
    }
}

Describe 'SetSQLServerESUSubscription eligibility and billing gates' {
    It 'rejects LicenseOnly, unsupported versions, and unsupported editions without mutation' {
        foreach ($scenario in @('LicenseOnly', 'UnsupportedVersion', 'UnsupportedEdition')) {
            $result = Invoke-SetScenario -Scenario $scenario
            $result.ExitCode | Should Be 1
            @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 0
        }
    }

    It 'requires nonproduction coverage for Developer and rejects Developer production' {
        $production = Invoke-SetScenario -Scenario Developer
        $missingGate = Invoke-SetScenario -Scenario Developer -AdditionalArguments '-Action Enable -Environment NonProduction -AcceptBackBilling -ConfirmExternalPrerequisites'
        $accepted = Invoke-SetScenario -Scenario Developer -AdditionalArguments '-Action Enable -Environment NonProduction -AcceptBackBilling -ConfirmExternalPrerequisites -ConfirmNonProductionCoverage'
        $production.ExitCode | Should Be 1
        $production.Output | Should Match 'Developer edition cannot establish production'
        $missingGate.ExitCode | Should Be 1
        $missingGate.Output | Should Match 'ConfirmNonProductionCoverage must be TRUE'
        $accepted.ExitCode | Should Be 0
    }

    It 'warns for stale inventory but still permits enablement' {
        $result = Invoke-SetScenario -Scenario Stale
        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'Inventory timestamp is Stale.*staleness alone does not block'
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 1
    }

    It 'reports mixed-version metering, physical and VM host type, detected cores, and the four-core minimum' {
        $mixed = Invoke-SetScenario -Scenario Mixed -AdditionalArguments '-DryRun'
        $physical = Invoke-SetScenario -Scenario Physical -AdditionalArguments '-DryRun'
        $virtual = Invoke-SetScenario -AdditionalArguments '-DryRun'
        $mixed.Output | Should Match 'each version can produce a separate ESU meter'
        $mixed.Output | Should Match 'SQL Server 2014,SQL Server 2016|SQL Server 2016,SQL Server 2014'
        $mixed.Output | Should Match 'Instances=MSSQLSERVER,SQL2014; ServiceTypes=DatabaseEngine,AnalysisServices'
        $physical.Output | Should Match 'HostType=PhysicalServer; DetectedCores=32'
        $virtual.Output | Should Match 'HostType=VirtualMachine; DetectedCores=2;.*four-core minimum'
    }

    It 'shows the exact billing-sensitive preview and no automatic patch or physical-pool mutation' {
        $result = Invoke-SetScenario -AdditionalArguments '-DryRun'
        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'current-year back-billing.*re-enable/reconnection bill-back'
        $result.Output | Should Match 'does not enable automatic patching'
        $result.Output | Should Match 'does not establish pooled physical-core unlimited virtualization'
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 0
    }
}

Describe 'SetSQLServerESUSubscription resilience and verification' {
    It 'honors WhatIf after read-only preflight and sends no mutation' {
        $result = Invoke-SetScenario -AdditionalArguments '-WhatIf'
        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'Previewed|What if'
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 0
    }

    It 'allows WhatIf cancellation when full eligibility evidence is unavailable' {
        $result = Invoke-SetScenario -Scenario EvidenceUnavailable -AdditionalArguments '-Action Disable -WhatIf'
        $result.ExitCode | Should Be 0
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 0
    }

    It 'polls a trusted asynchronous Location and performs final verification' {
        $result = Invoke-SetScenario -Scenario Async
        $result.ExitCode | Should Be 0
        @($result.Calls | Where-Object Uri -eq 'https://management.azure.com/operations/esu-01').Count | Should Be 2
        @($result.Calls | Where-Object { $_.Method -eq 'GET' -and $_.Uri -match '/extensions/WindowsAgent.SqlServer' }).Count | Should Be 2
    }

    It 'rejects an untrusted asynchronous Location' {
        $result = Invoke-SetScenario -Scenario UnsafeAsync
        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'untrusted operation polling URL'
    }

    It 'retries transient PUT failures' {
        $result = Invoke-SetScenario -Scenario TransientPut
        $result.ExitCode | Should Be 0
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 2
        (($result.Calls | Where-Object Method -eq 'SLEEP').Body -join ',') | Should Match '0'
    }

    It 'uses exponential retry fallback when Retry-After is absent' {
        $result = Invoke-SetScenario -Scenario TransientPutFallback
        $sleeps = @($result.Calls | Where-Object Method -eq 'SLEEP' | ForEach-Object { [int]$_.Body })
        $result.ExitCode | Should Be 0
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 4
        ($sleeps -join ',') | Should Be '2,4,8'
    }

    It 'retries a succeeded but stale verification read until settings converge' {
        $result = Invoke-SetScenario -Scenario VerificationConverges
        $result.ExitCode | Should Be 0
        @($result.Calls | Where-Object { $_.Method -eq 'GET' -and $_.Uri -match '/extensions/WindowsAgent.SqlServer' }).Count | Should Be 3
    }

    It 'bounds settings mismatch verification and reports timeout' {
        $result = Invoke-SetScenario -Scenario VerificationMismatch
        $verificationSleeps = @($result.Calls | Where-Object Method -eq 'SLEEP' | ForEach-Object { [int]$_.Body })
        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'Final extension verification timed out after 12 polls'
        $result.Output | Should Match 'enableExtendedSecurityUpdates'
        @($result.Calls | Where-Object { $_.Method -eq 'GET' -and $_.Uri -match '/extensions/WindowsAgent.SqlServer' }).Count | Should Be 13
        ($verificationSleeps | Measure-Object -Maximum).Maximum | Should Be 60
    }

    It 'fails unrelated settings mismatch after bounded retries' {
        $result = Invoke-SetScenario -Scenario UnrelatedMismatch
        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'Final extension verification timed out'
        $result.Output | Should Match 'unrelated settings'
    }

    It 'uses the row subscription override for cancellation extension reads and writes' {
        $csv = @"
SubscriptionId,ServerResourceGroupName,ARCServerName,Action,LicenseType,Environment,AcceptBackBilling,AcceptLicenseTypeChange,ConfirmNonProductionCoverage,ConfirmExternalPrerequisites
$overrideSubscriptionId,server-rg,server-01,Disable,,,,,,
"@
        $result = Invoke-SetScenario -Scenario AlreadyEnabled -CsvContent $csv
        $extensionCalls = @($result.Calls | Where-Object { $_.Uri -match '/extensions/WindowsAgent.SqlServer' })
        $result.ExitCode | Should Be 0
        $extensionCalls.Count | Should Be 3
        @($extensionCalls | Where-Object { $_.Uri -notmatch "/subscriptions/$overrideSubscriptionId/" }).Count | Should Be 0
    }

    It 'completes all Azure preflight before the first mutation' {
        $csv = @"
SubscriptionId,ServerResourceGroupName,ARCServerName,Action,LicenseType,Environment,AcceptBackBilling,AcceptLicenseTypeChange,ConfirmNonProductionCoverage,ConfirmExternalPrerequisites
$subscriptionId,server-rg,server-01,Enable,,Production,TRUE,FALSE,FALSE,TRUE
$subscriptionId,server-rg,server-02,Enable,,Production,TRUE,FALSE,FALSE,TRUE
"@
        $result = Invoke-SetScenario -CsvContent $csv
        $firstPut = [array]::IndexOf([object[]]$result.Calls, ($result.Calls | Where-Object Method -eq 'PUT' | Select-Object -First 1))
        $extensionGetsBeforePut = @($result.Calls[0..($firstPut - 1)] | Where-Object { $_.Method -eq 'GET' -and $_.Uri -match '/extensions/WindowsAgent.SqlServer' }).Count
        $result.ExitCode | Should Be 0
        $extensionGetsBeforePut | Should Be 2
    }

    It 'continues bulk execution after a runtime failure and returns exit 1' {
        $csv = @"
SubscriptionId,ServerResourceGroupName,ARCServerName,Action,LicenseType,Environment,AcceptBackBilling,AcceptLicenseTypeChange,ConfirmNonProductionCoverage,ConfirmExternalPrerequisites
$subscriptionId,server-rg,server-01,Enable,,Production,TRUE,FALSE,FALSE,TRUE
$subscriptionId,server-rg,server-02,Enable,,Production,TRUE,FALSE,FALSE,TRUE
"@
        $result = Invoke-SetScenario -Scenario RuntimeFailure -CsvContent $csv
        $result.ExitCode | Should Be 1
        @($result.Calls | Where-Object { $_.Method -eq 'PUT' -and $_.Uri -match '/server-01/' }).Count | Should Be 4
        @($result.Calls | Where-Object { $_.Method -eq 'PUT' -and $_.Uri -match '/server-02/' }).Count | Should Be 1
        ($result.Output -replace '\s+', ' ') | Should Match 'Planned: 2; Succeeded: 1; Already compliant: 0; Previewed: 0; Declined: 0; Failed: 1; Not started: 0'
    }

    It 'supports service principal authentication without exposing credentials' {
        $result = Invoke-SetScenario -ServicePrincipal -AdditionalArguments '-DryRun'
        $result.ExitCode | Should Be 0
        @($result.Calls | Where-Object IsAuthentication).Count | Should Be 1
        $result.Output | Should Not Match 'fictitious-client-secret|fictitious-access-token'
    }
}